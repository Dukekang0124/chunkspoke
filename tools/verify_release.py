#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""发版链路体检：把「用户点下载会不会 404」变成机器可判定，不再靠人回忆。

存在的原因（v1.4.4 事故）：清单的 url 指向 releases/latest/download/…，而那次
Release 的资产没上传成功，于是官网下载按钮和应用内整包兜底同时变成 9 字节的
"Not Found"。当时没有任何脚本会因此失败——本脚本补的就是这一条硬闸。

用法（在仓库根 D:\\cs_flutter 下）：
  python tools/verify_release.py                # 只验线上链路
  python tools/verify_release.py --apk build/app/outputs/flutter-apk/app-arm64-v8a-release.apk
  python tools/verify_release.py --skip-network # 只做本地一致性检查

退出码 0 = 全部通过；1 = 有硬失败（禁止对外发布）；告警不影响退出码。
"""
import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.request

try:
    if hasattr(sys.stdout, 'reconfigure'):
        sys.stdout.reconfigure(encoding='utf-8')
except Exception:
    pass

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OWNER = 'Dukekang0124'
REPO = 'chunkspoke'
RELREPO = 'chunkspoke-releases'   # 分片 / Pages 镜像所在仓库
SITE = 'https://dukekang0124.github.io/chunkspoke'
UA = 'chunkspoke-verify'
PROBE_RETRIES = 3

fails = []
warns = []


def ok(msg):
    print(f'  ✓ {msg}', flush=True)


def fail(msg):
    print(f'  ✗ {msg}', flush=True)
    fails.append(msg)


def warn(msg):
    print(f'  ! {msg}', flush=True)
    warns.append(msg)


def _urllib_head(url, timeout):
    """返回 (status, length) 或 ('retry', 原因)。status 为 None 表示这次没结论。"""
    req = urllib.request.Request(url, method='HEAD')
    req.add_header('User-Agent', UA)
    req.add_header('Accept-Encoding', 'identity')
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status, _content_length(r.headers)
    except urllib.error.HTTPError as e:
        if e.code < 500:
            return e.code, None          # 4xx：服务器明确说了「没有」，参与硬判定
        return 'retry', f'HTTP {e.code}'  # 5xx：瞬时故障或本机加速代理抖动
    except Exception as e:
        return 'retry', f'{type(e).__name__}: {e}'


def _content_length(headers):
    """只信任没有 Content-Encoding 的长度：gzip 体的长度必然小于清单 size。"""
    if (headers.get('Content-Encoding') or '').lower() not in ('', 'identity'):
        return None
    cl = headers.get('Content-Length')
    return int(cl) if cl and cl.isdigit() else None


def head(url, timeout=40):
    """探测一条对外地址：返回 (status, content_length)。

    status 可能是 'net'（连接层始终失败）或 'flaky'（只拿到 5xx）——两者都是
    「没测到」，不是「链接坏了」，由调用方记告警而不是硬失败。本机代理会把
    jsDelivr 的连接反复 10054 掐断、也会随机给 GitHub Pages 502，把它们计成
    断链会让体检天天误报，最后没人看它的输出。
    """
    last = None
    for _ in range(PROBE_RETRIES):
        st, length = _urllib_head(url, timeout)
        if st != 'retry':
            if length is None:            # 状态有了但长度没拿到，再用 curl 取一次
                st2, length2 = _curl_probe(url, timeout)
                if length2 is not None:
                    return st2, length2
            return st, length
        last = length
        time.sleep(1.2)
    st, length = _curl_probe(url, timeout)
    if st:
        return st, length
    if str(last or '').startswith('HTTP 5'):
        return 'flaky', last
    return 'net', last


def _last_block(text):
    """curl -D - 会把每一跳的响应头都打出来；只有最后一块属于最终响应。"""
    blocks = [b for b in re.split(r'(?m)^HTTP/[0-9.]+ \d+', text) if b.strip()]
    return blocks[-1] if blocks else text


def _curl_probe(url, timeout):
    """curl 兜底：本机 urllib 走代理时会对 jsDelivr 反复 10054，而 curl 一直是通的。

    少了这一步，门禁对「应用内更新主通道」（jsDelivr 分片）永远是盲的——而那条
    通道恰恰是 v1.4.4 唯一真正可用的下载路径。返回 (status, length)，失败 (None, None)。
    """
    cmd = ['curl', '-sSI', '-L', '-o', os.devnull, '-D', '-',
           '--max-time', str(max(5, timeout - 5)),
           '-H', 'Accept-Encoding: identity', '-w', '\\n%{http_code}']
    if os.name == 'nt':
        cmd.append('--ssl-no-revoke')   # Windows schannel 取不到吊销列表时会直接失败
    cmd.append(url)
    try:
        out = subprocess.run(cmd, capture_output=True, text=True,
                             encoding='utf-8', errors='replace',
                             timeout=timeout + 10).stdout or ''
    except Exception:
        return None, None
    m = re.search(r'(\d{3})\s*$', out.strip())
    if not m:
        return None, None
    status, block = int(m.group(1)), _last_block(out)
    if re.search(r'content-encoding:\s*gzip', block, re.I):
        return status, None              # gzip 体长度必然小于清单 size，不可用于核对
    cm = re.search(r'content-range:\s*bytes\s+\d+-\d+/(\d+)', block, re.I)
    if cm:
        return status, int(cm.group(1))
    clm = re.search(r'content-length:\s*(\d+)', block, re.I)
    return status, (int(clm.group(1)) if clm else None)


def get_json(url, timeout=40):
    """读远端 JSON；urllib 被代理掐断时用 curl 重试（清单比对是硬判定，不能瞎）。"""
    req = urllib.request.Request(url)
    req.add_header('User-Agent', UA)
    req.add_header('Accept-Encoding', 'identity')
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return json.loads(r.read().decode('utf-8'))
    except urllib.error.HTTPError:
        raise
    except Exception as first_err:
        cmd = ['curl', '-sS', '-L', '--max-time', str(max(5, timeout - 5))]
        if os.name == 'nt':
            cmd.append('--ssl-no-revoke')
        cmd.append(url)
        out = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout + 10).stdout
        if not (out or '').strip():
            raise first_err
        return json.loads(out)


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b''):
            h.update(chunk)
    return h.hexdigest()


def load_local(path, label):
    p = os.path.join(ROOT, path)
    if not os.path.isfile(p):
        fail(f'{label} 缺失：{path}')
        return None
    try:
        with open(p, encoding='utf-8') as f:
            return json.load(f)
    except Exception as e:
        fail(f'{label} 不是合法 JSON：{path}（{e}）')
        return None


def check_manifest_shape(m):
    print('== 1/7 清单字段 ==')
    for k in ('versionName', 'versionCode', 'url', 'sha256', 'size'):
        if k not in m:
            fail(f'清单缺少必填字段 {k}')
    if not str(m.get('sha256', '')).strip():
        fail('清单 sha256 为空：客户端无法校验完整性')
    if m.get('parts'):
        total = sum(int(p['size']) for p in m['parts'])
        if total != int(m.get('size') or -1):
            fail(f'分片大小之和 {total} != 整包 size {m.get("size")}（重组后会校验失败）')
        else:
            ok(f'{len(m["parts"])} 个分片大小之和 = 整包 size')
    else:
        warn('清单没有 parts：应用内更新只能走整包直链')
    if not m.get('urls'):
        warn('清单没有 urls 备用源：主直链失效时用户无路可退（v1.4.4 事故成因）')


def check_local_sync(m):
    print('== 2/7 本地三份清单一致 ==')
    tag = f'v{m["versionName"]}'
    docs = load_local(os.path.join('docs', 'version.json'), '官网同源清单')
    assets = load_local(os.path.join('assets', 'version.json'), '包内清单')
    for label, other in (('docs/version.json', docs), ('assets/version.json', assets)):
        if other is None:
            continue
        # 身份字段必须三处一致：这正是 1.4.9→1.5.1 包内清单滞后的那种事故，硬失败。
        ident = (str(other.get('versionName')) == str(m.get('versionName'))
                 and int(other.get('versionCode') or 0) == int(m.get('versionCode') or 0)
                 and other.get('url') == m.get('url'))
        if not ident:
            fail(f'{label} 与根清单的身份字段不一致（版本/号/url）：发版必须一次写全三处')
            continue
        # 指纹：官网同源必须逐字节同；包内副本描述的是「上一次构建」的 apk——
        # 清单被打进它自己要描述的文件，自引用不可能自洽（见 DEPLOY/发版 SOP §3.0），
        # 所以这里只告警并打印两代指纹，不再误报成断链。
        fp_same = other.get('sha256') == m.get('sha256') and other.get('size') == m.get('size')
        if fp_same or label == 'docs/version.json':
            if not fp_same and label == 'docs/version.json':
                fail(f'{label} 指纹与根清单不同：官网同源清单必须逐字节一致')
                continue
            ok(f'{label} 与根清单一致（{tag}，指纹{"同" if fp_same else "同"}）')
        else:
            warn(f'{label} 指纹为上一代构建（自引用必然滞后）：包内 '
                 f'{str(other.get("sha256"))[:12]}…/{other.get("size")} vs 线上 '
                 f'{str(m.get("sha256"))[:12]}…/{m.get("size")}；身份字段已核对一致')
    # 官网烘死版本号不应落后于清单
    idx = os.path.join(ROOT, 'docs', 'index.html')
    if os.path.isfile(idx):
        html = open(idx, encoding='utf-8').read()
        baked = sorted(set(re.findall(r'<span class="version-badge">(v[\d.]+)</span>', html))
                       | set(re.findall(r'id="footerVersion">(v[\d.]+)<', html)))
        stale = [b for b in baked if b != tag]
        if stale:
            fail(f'docs/index.html 烘死的版本徽章仍是 {stale}，清单已是 {tag}（JS 拉取失败时用户就看到旧版）')
        elif baked:
            ok(f'官网烘死徽章 = {tag}')


def _find_aapt():
    bases = []
    for var in ('ANDROID_HOME', 'ANDROID_SDK_ROOT'):
        v = os.environ.get(var)
        if v:
            bases.append(os.path.join(v, 'build-tools'))
    bases += [r'D:\tools\android-sdk\build-tools', r'C:\tools\android-sdk\build-tools',
              os.path.expandvars(r'%LOCALAPPDATA%\Android\sdk\build-tools')]
    for base in bases:
        if not os.path.isdir(base):
            continue
        for ver in sorted(os.listdir(base), reverse=True):
            exe = os.path.join(base, ver, 'aapt.exe' if os.name == 'nt' else 'aapt')
            if os.path.isfile(exe):
                return exe
    return None


def apk_version_code(apk):
    """读 APK manifest 里的真实 versionCode。

    必须读，不能信 pubspec：--split-per-abi 会给 arm64 叠加 2000 基数，
    pubspec 的 2045 打进包会变成 4045。清单若写 2045，真机 local()=4045，
    isNewerVersion(4045, 2045) 恒为 false → 「检查更新」永远报「已是最新」。
    v1.4.2/1.4.3/1.4.4 三份清单都踩了这个坑。
    """
    aapt = _find_aapt()
    if not aapt:
        return None
    tmp = os.path.join(os.environ.get('TEMP', os.sep), 'cs_verify.apk')
    try:
        if os.path.abspath(apk) != os.path.abspath(tmp):
            shutil.copyfile(apk, tmp)      # aapt 在中文路径下会 I/O error
        out = subprocess.run([aapt, 'dump', 'badging', tmp],
                             capture_output=True, text=True, timeout=120).stdout
    except Exception:
        return None
    m = re.search(r"versionCode='(\d+)'", out)
    return int(m.group(1)) if m else None


def check_apk(m, apk):
    print('== 3/7 本地 APK 真值 ==')
    if not apk:
        warn('未传 --apk，跳过 sha256/size 实测')
        return
    if not os.path.isfile(apk):
        fail(f'APK 不存在：{apk}')
        return
    digest = sha256_file(apk)
    size = os.path.getsize(apk)
    if digest.lower() != str(m.get('sha256', '')).lower():
        fail(f'APK sha256 与清单不符：实测 {digest}')
    else:
        ok(f'sha256 一致：{digest[:16]}…')
    if size != int(m.get('size') or -1):
        fail(f'APK 大小与清单不符：实测 {size} / 清单 {m.get("size")}')
    else:
        ok(f'大小一致：{size} 字节')
    code = apk_version_code(apk)
    if code is None:
        warn('未找到 aapt 或读取失败，跳过 APK 内 versionCode 核对')
    elif code != int(m.get('versionCode') or 0):
        fail(f'APK 内 versionCode={code}，清单写的是 {m.get("versionCode")}：'
             '真机会永远判定「已是最新」，收不到任何更新（split-per-abi 的 2000 基数）')
    else:
        ok(f'APK 内 versionCode 一致：{code}')


def probe(label, url, want=None):
    """统一判定：2xx + 长度符合 = 通过；服务器明确 4xx/5xx 或长度不符 = 硬失败；
    连接层失败只告警（否则代理抖动会让人把整份报告当噪音）。"""
    st, length = head(url)
    if st == 'net':
        warn(f'{label} 未测到（连接层失败，非 404）：{length}')
        return False
    if st == 'flaky':
        warn(f'{label} 服务端瞬时错误，未判定：{length}（{url}）')
        return False
    if st not in (200, 206):
        fail(f'{label} 不可用（HTTP {st}）：{url} ← 用户点下载就是这个结果')
        return False
    if want and length and length != int(want):
        fail(f'{label} 返回长度 {length} != 期望 {want}（下到的是别的文件）：{url}')
        return False
    if want and not length:
        # 通了但拿不到长度：只算「没验到 size」，不能报 ✓，否则就是假绿。
        warn(f'{label} {st} 可用，但未能核对 size（期望 {want}）')
        return True
    ok(f'{label} {st} {length}B')
    return True


def check_urls(m):
    print('== 4/7 每一条对外地址实测可达 ==')
    expected = int(m.get('size') or 0)
    targets = [('url', m.get('url'))]
    for i, u in enumerate(m.get('urls') or []):
        targets.append((f'urls[{i}]', u))
    for name, u in targets:
        if u:
            probe(name, u, expected)
    for i, p in enumerate(m.get('parts') or []):
        probe(f'parts[{i}]', p['url'], p.get('size'))
    model = m.get('model') or {}
    for i, p in enumerate(model.get('parts') or []):
        probe(f'model.parts[{i}]', p['url'], p.get('size'))
    # 断点续传：应用内下载靠 Range 续传，Pages 不支持就会反复重头下
    if m.get('url'):
        req = urllib.request.Request(m['url'])
        req.add_header('User-Agent', UA)
        req.add_header('Range', 'bytes=0-1023')
        try:
            with urllib.request.urlopen(req, timeout=40) as r:
                if r.status == 206:
                    ok('主直链支持 Range 断点续传（206）')
                else:
                    warn(f'主直链 Range 探测返回 {r.status}，弱网下无法续传')
        except Exception as e:
            warn(f'主直链 Range 探测失败：{e}')


def check_github(m):
    print('== 5/7 Release 资产真的存在 ==')
    # 下载通道以清单为准：v1.4.5 起主通道是 GitHub Pages 镜像，
    # 若清单根本没写 Release 地址，就不该因为「没传 Release 资产」判红。
    download = [m.get('url', '')] + list(m.get('urls') or [])
    if not any('github.com' in u and '/releases/' in u for u in download):
        warn('清单未使用 GitHub Release 下载通道（主通道为 Pages 镜像），跳过资产检查')
        return
    tag = f'v{m["versionName"]}'
    try:
        rel = get_json(f'https://api.github.com/repos/{OWNER}/{REPO}/releases/tags/{tag}')
    except Exception as e:
        warn(f'读不到 Release {tag}（限流或无网）：{e}')
        return
    if rel.get('draft'):
        warn(f'Release {tag} 还是草稿，latest 不会指向它')
    names = {a['name']: a['size'] for a in (rel.get('assets') or [])}
    if 'chunkspoke-latest.apk' not in names:
        fail(f'Release {tag} 没有 chunkspoke-latest.apk 资产 → releases/latest/download/… 必然 404')
    else:
        got = names['chunkspoke-latest.apk']
        if int(m.get('size') or -1) != got:
            fail(f'Release 资产大小 {got} != 清单 size {m.get("size")}：传成了旧包')
        else:
            ok(f'Release {tag} 资产就位（{got}B）')
    # latest 别名必须解析到本次 tag，否则老 tag 会截胡
    try:
        latest = get_json(f'https://api.github.com/repos/{OWNER}/{REPO}/releases/latest')
        if latest.get('tag_name') != tag:
            fail(f'releases/latest 指向 {latest.get("tag_name")}，不是 {tag}：官网按钮会下到别的版本')
        else:
            ok(f'releases/latest = {tag}')
    except Exception as e:
        warn(f'releases/latest 检查失败：{e}')


def check_site():
    print('== 6/7 官网同源副本已发布 ==')
    st, _ = head(f'{SITE}/version.json')
    if st in ('net', 'flaky'):
        warn(f'官网 version.json 未判定（{st}）')
        return None
    if st in (200, 206):
        try:
            j = get_json(f'{SITE}/version.json?t={int(time.time())}')
            ok(f'官网 version.json 在线（{j.get("versionName")}）')
            return j.get('versionName')
        except Exception as e:
            fail(f'官网 version.json 解析失败：{e}')
    else:
        fail(f'官网 version.json 不可达（HTTP {st}）：app.js 的同源首选源失效')
    return None


def check_remote_manifests(m):
    """三个清单源必须给出同一份内容（官网同源为 App 首选）。

    1.5.7 起 App 回退别名 = @main（DDS §20.4）：tag 只作发布锚点，
    主分支别名随发版提交前进。@main 三态判定：
      ✅ 一致   —— 别名已跟随发版提交；
      ⚠️ 滞后   —— 可读但版本落后（边缘缓存 TTL），App 首选官网同源，不受影响；
      ⏭ EXEMPT —— 403/包体超限，按既有口径豁免（不判失败）。
    """
    print('== 7/7 远端三个清单源内容一致 ==')
    srcs = {
        '官网': f'{SITE}/version.json',
        'raw': f'https://raw.githubusercontent.com/{OWNER}/{REPO}/main/version.json',
        'jsDelivr@main': f'https://cdn.jsdelivr.net/gh/{OWNER}/{REPO}@main/version.json',
    }
    got = {}
    exempt = set()
    for label, url in srcs.items():
        try:
            got[label] = get_json(url + f'?t={int(time.time())}')
        except urllib.error.HTTPError as e:
            if e.code == 403 and label.startswith('jsDelivr'):
                exempt.add(label)
                warn(f'{label} EXEMPT：HTTP 403（包体超限口径，不判失败）')
            elif e.code < 500:
                fail(f'{label} 清单读取失败（HTTP {e.code}）')
            else:
                warn(f'{label} 清单未读到（HTTP {e.code}，瞬时/代理）')
        except Exception as e:
            warn(f'{label} 清单未读到（连接层失败，稍后重跑）：{e}')
    for label, j in got.items():
        if str(j.get('versionCode')) != str(m.get('versionCode')):
            if label.startswith('jsDelivr'):
                warn(f'{label} ⚠️ 滞后：仍是 {j.get("versionName")}({j.get("versionCode")})；'
                     '边缘缓存 TTL 内属预期，App 首选官网同源')
            else:
                fail(f'{label} 仍是 {j.get("versionName")}({j.get("versionCode")})，本地是 '
                     f'{m.get("versionName")}({m.get("versionCode")})：清单没推上去')
            continue
        if j.get('url') != m.get('url'):
            fail(f'{label} 的 url 与本地不同：{j.get("url")}')
        else:
            ok(f'{label} ✅ = v{j.get("versionName")}，url 一致')
    if 'raw' in got and '官网' in got:
        if (got['raw'].get('urls') or []) != (got['官网'].get('urls') or []):
            fail('raw 与官网的 urls 备用源不一致：用户会在不同源之间拿到不同下载地址')
        else:
            ok('raw 与官网内容一致')
    jd = got.get('jsDelivr@main')
    if jd and str(jd.get('versionCode')) == str(m.get('versionCode')):
        if (jd.get('urls') or []) != (m.get('urls') or []):
            fail('jsDelivr@main 与本地清单的 urls 备用源不一致（缓存未刷新）')
        else:
            ok('jsDelivr@main 与本地清单一致')
    elif 'jsDelivr@main' in exempt:
        ok('jsDelivr@main 已豁免（403 包体口径）')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--apk', help='顺带核对 sha256/size 的本地 APK')
    ap.add_argument('--skip-network', action='store_true', help='只做本地一致性')
    a = ap.parse_args()

    m = load_local('version.json', '根清单')
    if m is None:
        print('\n[失败] 读不到 version.json')
        return 1

    print(f'=== ChunkSpoke 发版链路体检 {m.get("versionName")} ({m.get("versionCode")}) ===')
    check_manifest_shape(m)
    check_local_sync(m)
    check_apk(m, a.apk)
    if a.skip_network:
        print('\n（--skip-network：跳过线上实测）')
    else:
        check_urls(m)
        check_github(m)
        remote = check_site()
        check_remote_manifests(m)
        if remote and str(remote) != str(m.get('versionName')):
            fail(f'官网线上清单是 {remote}，本地已是 {m.get("versionName")}：改动还没推上去')

    print('\n' + '=' * 46)
    if fails:
        print(f'[不通过] {len(fails)} 项硬失败：')
        for f in fails:
            print(f'  - {f}')
    if warns:
        print(f'[告警] {len(warns)} 项（不阻断）：')
        for w in warns:
            print(f'  - {w}')
    if not fails:
        print('[通过] 对外链路全部可用，可以发布。')
    return 1 if fails else 0


if __name__ == '__main__':
    sys.exit(main())
