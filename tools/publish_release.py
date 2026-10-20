#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""一条命令发布 ChunkSpoke 应用内更新（GitHub Release 资产 + main 分支 version.json）。

为什么需要它：
  App 内「检查更新」读的是 `main/version.json`，下载读的是
  `releases/latest/download/chunkspoke-latest.apk`。两者必须同时更新，
  且清单里的 sha256/size 必须等于**真正上传的那个 APK**，否则客户端
  「校验失败 / 下载不完整」。手点网页很容易漏掉其中一步。

用法：
  推荐直接双击/运行 tools/publish.bat（自动切目录 + 交互式要 Token）。
  手动执行（在仓库根 D:\\cs_flutter 下，路径用 / 避免转义问题）：
  set GITHUB_TOKEN=ghp_xxx            # PowerShell: $env:GITHUB_TOKEN="ghp_xxx"
  python tools/publish_release.py --apk ../chunkspoke-v1.2.8-arm64.apk --dry-run
  python tools/publish_release.py --apk ../chunkspoke-v1.2.8-arm64.apk

  只修清单不动 APK（例如下面 v1.4.4 的补发布）：
  python tools/publish_release.py --apk build/app/outputs/flutter-apk/app-arm64-v8a-release.apk --manifest-only

本脚本一次写全四处，缺一不可：
  version.json（远端 main，App 首选源）
  docs/version.json（官网同源首选源，GitHub Pages 直接对外发）
  assets/version.json（打进 APK 的离线兜底，必须在 flutter build 之前写好）
  GitHub Release 资产 chunkspoke-latest.apk（缺了它 releases/latest/download/… 就是 404）

可选：
  --mirror-url https://mirror.example.com/chunkspoke-latest.apk   # 追加进 version.json 的 urls（可重复）
  --skip-manifest    # 只发 APK，不动 version.json
  --manifest-only    # 只推清单（含 docs/version.json），不重传 APK
  --skip-verify      # 跳过线上自检与链路体检：只在调试时用，它正是拦住 404 的那道闸
  --token XXX        # 也可直接传（会留在 shell 历史里，不推荐）

发布后仍要单独确认的一件事：APK 分片（App 内更新的主通道）不在本脚本职责内，
由 tools/split_apk.py 切分后推 chunkspoke-releases 仓库；verify_release.py 会逐条实测。

Token 权限：经典 PAT 需 `repo`；细粒度 PAT 需该仓库的 Contents: Read/Write。
"""

import argparse
import base64
import hashlib
import json
import os
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request

try:
    if hasattr(sys.stdout, 'reconfigure'):
        sys.stdout.reconfigure(encoding='utf-8')
except Exception:
    pass

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))  # 仓库根 = Flutter 工程根
# 注意：这里不能再往上一层找「仓库根」。旧结构是 仓库根/chunkspoke-flutter/，
# 现在工程本身就是仓库根（构建用的 ASCII 联结 D:\cs_flutter 也指向它）。
# 曾经 REPO_ROOT=dirname(ROOT) 会把清单写到工程外面（历史镜像副本里），
# 于是 version.json 与 assets/version.json 各说各话、v1.4.4 的 404 也没人拦。
REPO_ROOT = ROOT
MANIFEST = os.path.join(ROOT, 'version.json')
ASSET_MANIFEST = os.path.join(ROOT, 'assets', 'version.json')
SITE_MANIFEST = os.path.join(ROOT, 'docs', 'version.json')  # 官网同源首选源
OWNER = 'Dukekang0124'
REPO = 'chunkspoke'
ASSET_NAME = 'chunkspoke-latest.apk'
API = 'https://api.github.com'
UA = 'chunkspoke-release-script'


def log(msg):
    print(msg, flush=True)


def die(msg):
    print(f'\n[失败] {msg}', file=sys.stderr, flush=True)
    sys.exit(1)


def api(method, path, token, data=None, raw=None):
    """调用 GitHub REST API；path 以 / 开头。"""
    url = path if path.startswith('http') else API + path
    body = raw if raw is not None else (json.dumps(data).encode('utf-8') if data is not None else None)
    req = urllib.request.Request(url, data=body, method=method)
    req.add_header('Authorization', f'Bearer {token}')
    req.add_header('Accept', 'application/vnd.github+json')
    req.add_header('X-GitHub-Api-Version', '2022-11-28')
    req.add_header('User-Agent', UA)
    if body is not None:
        req.add_header('Content-Type', 'application/json')
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            payload = r.read()
            return json.loads(payload) if payload else None
    except urllib.error.HTTPError as e:
        detail = e.read().decode('utf-8', 'replace')[:400]
        if e.code == 404:
            return None
        die(f'{method} {url} → HTTP {e.code}\n{detail}')
    except urllib.error.URLError as e:
        die(f'{method} {url} 网络不可达：{e.reason}')


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b''):
            h.update(chunk)
    return h.hexdigest()


def read_apk_version_code(apk):
    """用 aapt 读 APK 内真实 versionCode（找不到 aapt 就返回 None）。"""
    cands = []
    ah = os.environ.get('ANDROID_HOME') or os.environ.get('ANDROID_SDK_ROOT')
    if ah:
        cands.append(os.path.join(ah, 'build-tools'))
    cands += [r'C:\tools\android-sdk\build-tools',
              os.path.expandvars(r'%LOCALAPPDATA%\Android\sdk\build-tools')]
    for base in cands:
        if not os.path.isdir(base):
            continue
        for name in sorted(os.listdir(base), reverse=True):
            exe = os.path.join(base, name, 'aapt.exe' if os.name == 'nt' else 'aapt')
            if not os.path.isfile(exe):
                continue
            try:
                # aapt 在中文路径下会 I/O error → 复制到 ASCII 临时目录再读
                tmp = os.path.join(tempfile.gettempdir(), 'cs_aapt_check.apk')
                if os.path.abspath(apk) != os.path.abspath(tmp):
                    with open(apk, 'rb') as s, open(tmp, 'wb') as d:
                        for chunk in iter(lambda: s.read(4 * 1024 * 1024), b''):
                            d.write(chunk)
                out = subprocess.run([exe, 'dump', 'badging', tmp],
                                     capture_output=True, text=True, timeout=120)
                for line in out.stdout.splitlines():
                    if line.startswith('package:'):
                        for part in line.split():
                            if part.startswith("versionCode='"):
                                return int(part.split("'")[1])
            except Exception:
                continue
    return None


def validate(apk, manifest):
    log('== 1/4 本地校验 ==')
    if not os.path.isfile(apk):
        die(f'APK 不存在：{apk}')
    size = os.path.getsize(apk)
    log(f'  APK：{apk}')
    log(f'  大小：{size} 字节（清单 {manifest.get("size")}）')
    if size != manifest.get('size'):
        die('APK 大小与 version.json 的 size 不一致：请用 tools/gen_version_json.py 重新生成清单')
    log('  正在计算 SHA-256（66MB，约 1-3 秒）…')
    digest = sha256_file(apk)
    if digest.lower() != str(manifest.get('sha256', '')).lower():
        die('APK 的 sha256 与 version.json 不一致：客户端会「校验失败」，已中止')
    log(f'  SHA-256 一致：{digest}')
    if int(manifest.get('versionCode') or 0) <= 0:
        die('version.json 缺少有效 versionCode')
    code = read_apk_version_code(apk)
    if code is None:
        log('  （未找到 aapt，跳过 APK 内 versionCode 核对）')
    elif code != int(manifest['versionCode']):
        die(f'APK 内 versionCode={code} 与清单 {manifest["versionCode"]} 不一致：'
            f'用户装完仍会被提示更新')
    else:
        log(f'  versionCode 一致：{code}')
    log(f'  清单版本：v{manifest["versionName"]}（{manifest["versionCode"]}）')


def upload_asset(token, release, apk):
    rel_id = release['id']
    for a in release.get('assets', []):
        if a['name'] == ASSET_NAME:
            log(f'  删除同名的旧资产：{ASSET_NAME}（{a["size"]} 字节）')
            api('DELETE', f'/repos/{OWNER}/{REPO}/releases/assets/{a["id"]}', token, raw=b'')
    size = os.path.getsize(apk)
    url = (f'https://uploads.github.com/repos/{OWNER}/{REPO}/releases/{rel_id}/assets'
           f'?name={ASSET_NAME}')
    log(f'  上传 {ASSET_NAME}（{size / 1024 / 1024:.1f} MB）…')
    started = time.time()
    with open(apk, 'rb') as f:
        req = urllib.request.Request(url, data=f, method='POST')
        req.add_header('Authorization', f'Bearer {token}')
        req.add_header('Content-Type', 'application/vnd.android.package-archive')
        req.add_header('Accept', 'application/vnd.github+json')
        req.add_header('User-Agent', UA)
        req.add_header('Content-Length', str(size))
        try:
            with urllib.request.urlopen(req, timeout=1800) as r:
                asset = json.loads(r.read())
        except urllib.error.HTTPError as e:
            die(f'上传失败 HTTP {e.code}：{e.read().decode("utf-8", "replace")[:400]}')
        except urllib.error.URLError as e:
            die(f'上传网络中断：{e.reason}')
    log(f'  上传完成：{asset["name"]}，用时 {time.time() - started:.0f}s，state={asset["state"]}')
    return asset


def publish_apk(token, apk, manifest):
    log('== 2/4 发布 GitHub Release ==')
    tag = f'v{manifest["versionName"]}'
    release = api('GET', f'/repos/{OWNER}/{REPO}/releases/tags/{tag}', token)
    if release:
        log(f'  Release {tag} 已存在，复用并替换资产')
    else:
        release = api('POST', f'/repos/{OWNER}/{REPO}/releases', token, data={
            'tag_name': tag,
            'name': f'ChunkSpoke {tag}',
            'body': manifest.get('notes', ''),
            'draft': False,
            'prerelease': False,
        })
        if not release:
            die('创建 Release 失败')
        log(f'  已创建 Release {tag}（{release["html_url"]}）')
    asset = upload_asset(token, release, apk)
    return release, asset


def update_manifest(token, manifest, mirrors, apk_ok):
    log('== 3/4 更新 main 分支 version.json ==')
    if not apk_ok:
        die('APK 未上传成功，拒绝更新清单（否则用户会被引导去下旧包）')
    data = dict(manifest)
    if mirrors:
        urls = [data.get('url', '')] + list(mirrors)
        seen, dedup = set(), []
        for u in urls:
            if u and u not in seen:
                seen.add(u)
                dedup.append(u)
        data['urls'] = dedup
        log(f'  写入备用下载源：{dedup[1:]}')
    text = json.dumps(data, ensure_ascii=False, indent=2) + '\n'

    # 同步三份本地副本：远端清单、包内清单、官网同源清单（下次构建/部署打进去了）
    for path in (ASSET_MANIFEST, SITE_MANIFEST, MANIFEST):
        with open(path, 'w', encoding='utf-8', newline='\n') as f:
            f.write(text)
        log(f'  本地写入：{os.path.relpath(path, REPO_ROOT)}')

    for remote_path in ('version.json', 'docs/version.json'):
        remote = api('GET', f'/repos/{OWNER}/{REPO}/contents/{remote_path}?ref=main', token)
        if not remote:
            # 官网同源副本可能从未提交过：没有 sha 就是新建文件。
            resp = api('PUT', f'/repos/{OWNER}/{REPO}/contents/{remote_path}', token, data={
                'message': f'chore(release): {remote_path} → v{data["versionName"]} ({data["versionCode"]})',
                'content': base64.b64encode(text.encode('utf-8')).decode('ascii'),
                'branch': 'main',
            })
        else:
            resp = api('PUT', f'/repos/{OWNER}/{REPO}/contents/{remote_path}', token, data={
                'message': f'chore(release): {remote_path} → v{data["versionName"]} ({data["versionCode"]})',
                'content': base64.b64encode(text.encode('utf-8')).decode('ascii'),
                'sha': remote['sha'],
                'branch': 'main',
            })
        if not resp:
            die(f'提交 {remote_path} 失败')
        log(f'  已提交 {remote_path}：{resp["commit"]["sha"][:10]} {resp["commit"]["html_url"]}')


def purge_jsdelivr():
    """兜底源 jsDelivr 对 @main 有约 12h 缓存；不清会长期返回旧清单。"""
    for path in ('version.json', 'docs/version.json'):
        log(f'  刷新 jsDelivr 缓存（兜底源）：{path} …')
        url = f'https://purge.jsdelivr.net/gh/{OWNER}/{REPO}@main/{path}'
        try:
            req = urllib.request.Request(url, headers={'User-Agent': UA})
            with urllib.request.urlopen(req, timeout=30) as r:
                data = json.loads(r.read())
            log(f'  purge 状态：{data.get("status")}（若显示 throttled，等 1 分钟再访问一次即可）')
        except Exception as e:
            log(f'  purge 失败，不影响发布（可手动打开 {url}）：{e}')


def http_get(url, head=False, extra=None, timeout=40):
    req = urllib.request.Request(url, method='HEAD' if head else 'GET')
    req.add_header('User-Agent', UA)
    for k, v in (extra or {}).items():
        req.add_header(k, v)
    return urllib.request.urlopen(req, timeout=timeout)


def verify(manifest):
    log('== 4/4 线上自检 ==')
    ver, code = manifest['versionName'], manifest['versionCode']
    ok = True

    raw = f'https://raw.githubusercontent.com/{OWNER}/{REPO}/main/version.json?t={int(time.time())}'
    try:
        with http_get(raw) as r:
            remote = json.loads(r.read().decode('utf-8'))
        match = str(remote.get('versionName')) == str(ver) and int(remote.get('versionCode') or 0) == int(code)
        log(f'  raw 清单：{remote.get("versionName")} / {remote.get("versionCode")} → '
            f'{"OK" if match else "不一致（raw 有约 5 分钟缓存，稍后重试）"}')
        ok &= match
    except Exception as e:
        log(f'  raw 清单读取失败：{e}')
        ok = False

    try:
        with http_get(f'https://cdn.jsdelivr.net/gh/{OWNER}/{REPO}@main/version.json') as r:
            jd = json.loads(r.read().decode('utf-8'))
        jd_ok = str(jd.get('versionName')) == str(ver) and int(jd.get('versionCode') or 0) == int(code)
        log(f'  jsDelivr 兜底清单：{jd.get("versionName")} / {jd.get("versionCode")} → '
            f'{"OK" if jd_ok else "仍是旧版本（刚 purge 完需 1-2 分钟生效）"}')
    except Exception as e:
        log(f'  jsDelivr 清单读取失败（不影响，raw 是主源）：{e}')

    apk_url = manifest['url']
    try:
        with http_get(apk_url, head=True) as r:
            length = r.headers.get('Content-Length')
        same = length is not None and int(length) == int(manifest['size'])
        log(f'  APK 直链 HEAD：{r.status} len={length} → {"OK" if same else "与清单 size 不一致"}')
        ok &= same
    except Exception as e:
        log(f'  APK 直链 HEAD 失败：{e}')
        ok = False

    try:
        with http_get(apk_url, extra={'Range': 'bytes=0-1023'}) as r:
            log(f'  断点续传探测：{r.status}（需 206）→ {"OK" if r.status == 206 else "不支持 Range"}')
            ok &= r.status == 206
    except Exception as e:
        log(f'  断点续传探测失败：{e}')
        ok = False

    log('\n' + ('[完成] 线上校验全部通过，旧版本客户端下次冷启动即可收到更新弹窗。'
                if ok else '[失败] 有校验项未通过，见上面日志。'))
    if not ok:
        die('线上自检未通过：清单或 APK 直链不可用，用户会下到坏包')
    return ok


def run_gate(apk):
    """发布后硬闸：任何一条对外地址断了就让整条流水线红掉。

    v1.4.4 就是栽在这里——旧 verify() 只把失败打进日志、退出码仍是 0，
    所以「下载按钮 404」这种事故既不会拦住发布，也不会出现在任何告警里。
    """
    log('== 附加：线上链路体检（tools/verify_release.py）==')
    cmd = [sys.executable, os.path.join(ROOT, 'tools', 'verify_release.py'), '--apk', apk]
    if subprocess.run(cmd).returncode != 0:
        die('链路体检未通过：有对外地址不可用或清单不同步，禁止就此收工')
    log('  链路体检通过 ✓')


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--apk', required=True, help='要发布的 APK（arm64-v8a release）')
    p.add_argument('--token', default=os.environ.get('GITHUB_TOKEN') or os.environ.get('GH_TOKEN'))
    p.add_argument('--mirror-url', action='append', default=[],
                   help='国内镜像直链，写进 version.json 的 urls（可重复）')
    p.add_argument('--skip-manifest', action='store_true', help='只发 APK，不改 version.json')
    p.add_argument('--manifest-only', action='store_true',
                   help='只改 version.json（如补备用下载源），不重发 APK')
    p.add_argument('--skip-verify', action='store_true')
    p.add_argument('--dry-run', action='store_true')
    args = p.parse_args()

    with open(MANIFEST, encoding='utf-8') as f:
        manifest = json.load(f)
    apk = os.path.abspath(args.apk)
    validate(apk, manifest)

    if args.dry_run:
        log('\n[dry-run] 校验通过，未做任何线上改动。去掉 --dry-run 即真正发布。')
        return
    if not args.token:
        die('缺少 GitHub Token：设置环境变量 GITHUB_TOKEN（需 repo 写权限）或传 --token')

    if args.manifest_only:
        log('== 2/4 按 --manifest-only 跳过 Release 上传 ==')
        update_manifest(args.token, manifest, args.mirror_url, True)
        purge_jsdelivr()
        if not args.skip_verify:
            verify(manifest)
            run_gate(apk)
        return

    _release, asset = publish_apk(args.token, apk, manifest)
    if args.skip_manifest:
        log('== 3/4 按 --skip-manifest 跳过 version.json ==')
    else:
        update_manifest(args.token, manifest, args.mirror_url, bool(asset))
        purge_jsdelivr()
    if not args.skip_verify:
        verify(manifest)
        run_gate(apk)


if __name__ == '__main__':
    main()
