#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""由已构建的 APK 生成 version.json（真值 sha256 / size）。

为什么需要这个脚本：
  version.json 的 sha256/size 必须与**真正上传的那个 APK** 完全一致，
  手写或从旧版本复制会直接导致客户端「校验失败」或「下载不完整」。
  本脚本只读 APK、算哈希、写 JSON，不改动任何构建产物。

用法（在 chunkspoke-flutter/ 下执行）：
  # 构建后自动取版本号并生成（最常用）
  python tools/gen_version_json.py --apk build/app/outputs/flutter-apk/app-arm64-v8a-release.apk \
      --url https://github.com/Dukekang0124/chunkspoke/releases/latest/download/chunkspoke-latest.apk

  # 显式指定版本 + 备用下载源
  python tools/gen_version_json.py --apk xx.apk --version 1.2.6 --code 2021 \
      --url https://cdn.example.com/chunkspoke-1.2.6.apk \
      --urls https://mirror.example.com/chunkspoke-1.2.6.apk

  # 顺带把 pubspec 的 version 也推进（慎用；默认不动）
  ... --bump-pubspec

输出：
  version.json           仓库根目录（上传到 GitHub 的那份远端清单）
  assets/version.json    打进包内的同一份（保持一致的展示信息）
"""
import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.request

try:
    if hasattr(sys.stdout, 'reconfigure'):
        sys.stdout.reconfigure(encoding='utf-8')
except Exception:
    pass

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def read_pubspec_version():
    p = os.path.join(ROOT, 'pubspec.yaml')
    with open(p, encoding='utf-8') as f:
        for line in f:
            m = re.match(r'^version:\s*([0-9][^\s+]*(?:\+[0-9]+)?)\s*$', line)
            if m:
                raw = m.group(1)
                if '+' in raw:
                    name, code = raw.split('+', 1)
                    return name, int(code)
                return raw, 0
    raise SystemExit('[gen] 未在 pubspec.yaml 找到 version')


def bump_pubspec(name, code):
    p = os.path.join(ROOT, 'pubspec.yaml')
    with open(p, encoding='utf-8') as f:
        s = f.read()
    s2 = re.sub(r'^version:\s*.*$', f'version: {name}+{code}', s, count=1, flags=re.M)
    if s2 != s:
        with open(p, 'w', encoding='utf-8') as f:
            f.write(s2)
        print(f'  ✓ pubspec.yaml version -> {name}+{code}')


def find_aapt():
    cands = []
    ah = os.environ.get('ANDROID_HOME') or os.environ.get('ANDROID_SDK_ROOT')
    if ah:
        cands.append(os.path.join(ah, 'build-tools'))
    for base in [r'C:\tools\android-sdk', r'D:\Android\sdk',
                 os.path.expandvars(r'%LOCALAPPDATA%\Android\sdk')]:
        cands.append(os.path.join(base, 'build-tools'))
    for c in cands:
        if os.path.isdir(c):
            for ver in sorted(os.listdir(c), reverse=True):
                p = os.path.join(c, ver, 'aapt.exe')
                if os.path.exists(p):
                    return p
    return None


def apk_version_code(aapt, apk):
    """实测 APK manifest 的 versionCode（split-per-abi 会叠加 ABI 基数）。"""
    try:
        out = subprocess.run([aapt, 'dump', 'badging', apk],
                             capture_output=True, text=True).stdout
    except Exception:
        return None
    m = re.search(r"versionCode='(\d+)'", out)
    return int(m.group(1)) if m else None


def apk_facts(path):
    h = hashlib.sha256()
    size = 0
    with open(path, 'rb') as f:
        for block in iter(lambda: f.read(1024 * 1024), b''):
            h.update(block)
            size += len(block)
    return h.hexdigest(), size


def check_url(url, timeout=15):
    """尽力而为的可达性检查，只告警不阻断。"""
    req = urllib.request.Request(url, method='HEAD')
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return f'{r.status} {r.headers.get("Content-Length") or "?"}B ' \
                   f'{r.headers.get("Content-Type") or ""}'.strip()
    except urllib.error.HTTPError as e:
        return f'HTTP {e.code}'
    except Exception as e:  # 网络/证书等原因
        return f'不可达（{type(e).__name__}）'


def write_json(path, obj):
    with open(path, 'w', encoding='utf-8') as f:
        json.dump(obj, f, ensure_ascii=False, indent=2)
        f.write('\n')
    print(f'  ✓ {os.path.relpath(path, ROOT)}')


def main():
    ap = argparse.ArgumentParser(description='由 APK 生成 version.json（真值 sha256/size）')
    ap.add_argument('--apk', required=True, help='已构建的 release APK 路径')
    ap.add_argument('--version', help='versionName，默认取 pubspec')
    ap.add_argument('--code', type=int, help='versionCode，默认取 pubspec；必须大于线上版本')
    ap.add_argument('--url', help='主下载直链；缺省时沿用现有 version.json')
    ap.add_argument('--urls', action='append', default=[], help='备用下载源，可重复')
    ap.add_argument('--notes', help='更新说明；缺省时沿用现有 version.json')
    ap.add_argument('--bump-pubspec', action='store_true', help='同步改写 pubspec 的 version')
    ap.add_argument('--no-check', action='store_true', help='跳过 URL 可达性检查')
    a = ap.parse_args()

    if not os.path.isfile(a.apk):
        raise SystemExit(f'[gen] APK 不存在：{a.apk}')

    cur_name, cur_code = read_pubspec_version()
    name = a.version or cur_name
    code = a.code if a.code is not None else cur_code

    old_path = os.path.join(ROOT, 'version.json')
    old = {}
    if os.path.isfile(old_path):
        try:
            with open(old_path, encoding='utf-8') as f:
                old = json.load(f)
        except Exception:
            old = {}

    url = (a.url or old.get('url') or '').strip()
    if not url:
        raise SystemExit('[gen] 缺少 --url，且现有 version.json 里没有可用地址')

    sha, size = apk_facts(a.apk)
    aapt = find_aapt()
    if aapt:
        actual = apk_version_code(aapt, a.apk)
        print(f'  manifest versionCode: {actual}')
        if actual is not None and actual != code:
            raise SystemExit(
                f'[gen] versionCode 不一致：pubspec/--code={code}，APK manifest={actual}。\n'
                '      split-per-abi 会给 arm64 叠加 2000 基数；请带\n'
                '      -P force-version-code-ignoring-abi=true 重新构建，\n'
                '      或把 --code 设为实测值（否则客户端永远判定「已是最新」）。')
    else:
        print('  (未找到 aapt，跳过 manifest versionCode 校验)')

    old_code = int(old.get('versionCode') or 0)
    if code <= old_code:
        print(f'  ⚠ versionCode {code} 未大于线上 {old_code}，客户端不会提示更新')

    urls = [u.strip() for u in [url, *a.urls] if u and u.strip()]
    urls = list(dict.fromkeys(urls))

    obj = {
        'versionName': name,
        'versionCode': code,
        'url': url,
        'sha256': sha,
        'size': size,
        'notes': a.notes if a.notes is not None else (old.get('notes') or ''),
    }
    if old.get('model'):
        obj['model'] = old['model']  # v1.4.2 模型外移清单（name/modelVersion/sha256/parts）跨版本保留
    if len(urls) > 1:
        obj['urls'] = urls  # 备用源：主源失败时客户端按顺序重试

    print('=== version.json 生成 ===')
    print(f'  APK     : {a.apk}')
    print(f'  版本    : {name} ({code})')
    print(f'  体积    : {size} B ({size / 1048576:.1f} MB)')
    print(f'  SHA-256 : {sha}')

    if not a.no_check:
        for u in urls:
            print(f'  可达性  : {check_url(u)}  <- {u}')

    write_json(old_path, obj)
    assets = os.path.join(ROOT, 'assets', 'version.json')
    if os.path.isdir(os.path.dirname(assets)):
        write_json(assets, obj)

    if a.bump_pubspec:
        bump_pubspec(name, code)

    print('=== 下一步 ===')
    print('  1) 把该 APK 以固定名 chunkspoke-latest.apk 上传 Release')
    print('  2) 把根目录 version.json 覆盖到仓库 main（或 CDN）')
    print('  3) 用旧版本手机验证：检查更新 → 下载 → 安装')


if __name__ == '__main__':
    main()
