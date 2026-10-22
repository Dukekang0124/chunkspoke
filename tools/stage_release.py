#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把三 ABI 生产包 + 分片 + 清单装配成一个待上传目录（结构与 1.5.1 完全一致）。

结构不变是有意义的：jsDelivr 分片 HEAD 403 的回退实测结论是按「片数/片长/命名」复用的，
结构一变结论就作废。本脚本产出的目录可直接交给上传与三源校验流程。

用法：
  python tools/stage_release.py --version-name 1.5.2 --base-code 2053 \
      --out D:/gtmp/rel152 --notes "..."
"""
import argparse
import hashlib
import json
import os
import shutil
import subprocess
import sys

LF = chr(10)  # 强制 LF：git 会把 CRLF 归一化，本地/远端要逐字节可比

try:
    if hasattr(sys.stdout, 'reconfigure'):
        sys.stdout.reconfigure(encoding='utf-8')
except Exception:
    pass

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
APK_DIR = os.path.join(ROOT, 'build', 'app', 'outputs', 'flutter-apk')
OWNER = 'Dukekang0124'
RELREPO = 'chunkspoke-releases'
PART = 15728640
# Flutter split-per-abi 的 ABI 基数（实测：v7a 3052、arm64 4052、x86_64 6052）
ABI = [('arm64-v8a', 'app-arm64-v8a-release.apk', 'chunkspoke-latest.apk', 2000),
       ('armeabi-v7a', 'app-armeabi-v7a-release.apk', 'chunkspoke-armeabi-v7a.apk', 1000),
       ('x86_64', 'app-x86_64-release.apk', 'chunkspoke-x86_64.apk', 4000)]


def sha(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b''):
            h.update(chunk)
    return h.hexdigest()


def aapt_code(apk):
    """实测 manifest versionCode，不接受脚本自证。"""
    bases = [os.path.join(os.environ.get('ANDROID_SDK_ROOT') or r'D:\tools\android-sdk',
                          'build-tools')]
    exe = None
    for b in bases:
        if os.path.isdir(b):
            for v in sorted(os.listdir(b), reverse=True):
                c = os.path.join(b, v, 'aapt.exe' if os.name == 'nt' else 'aapt')
                if os.path.isfile(c):
                    exe = c
                    break
        if exe:
            break
    if not exe:
        return None
    tmp = os.path.join(os.environ.get('TEMP', os.sep), 'cs_stage.apk')
    if os.path.abspath(apk) != os.path.abspath(tmp):
        shutil.copyfile(apk, tmp)
    import re
    out = subprocess.run([exe, 'dump', 'badging', tmp], capture_output=True,
                         text=True, timeout=180).stdout
    m = re.search(r"versionCode='(\d+)'", out)
    return int(m.group(1)) if m else None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--version-name', required=True)
    ap.add_argument('--base-code', type=int, required=True, help='pubspec 的 +N，如 2053')
    ap.add_argument('--out', required=True)
    ap.add_argument('--notes', required=True)
    a = ap.parse_args()

    os.makedirs(os.path.join(a.out, 'parts'), exist_ok=True)
    gen = os.path.join(ROOT, 'tools', 'gen_release_manifest.py')
    arm64 = os.path.join(APK_DIR, 'app-arm64-v8a-release.apk')

    # 1) 线上清单（描述最终 arm64 包本体）
    subprocess.run([sys.executable, gen, '--apk', arm64,
                    '--version-name', a.version_name,
                    '--version-code', str(a.base_code + 2000),
                    '--notes', a.notes,
                    '--out', os.path.join(a.out, 'version.json')], check=True)

    # 2) 三 ABI 包 + 实测 versionCode 核对
    pkgs, facts = [], {}
    for abi, src, dst, base in ABI:
        s = os.path.join(APK_DIR, src)
        d = os.path.join(a.out, dst)
        shutil.copyfile(s, d)
        measured = aapt_code(s)
        expect = a.base_code + base
        if measured != expect:
            raise SystemExit(f'[中止] {abi} 实测 versionCode={measured} != 期望 {expect}')
        url = (f'https://dukekang0124.github.io/{RELREPO}/apk/{a.version_name}/{dst}')
        pkgs.append({'abi': abi, 'versionCode': measured, 'file': dst,
                     'size': os.path.getsize(d), 'sha256': sha(d), 'url': url,
                     'raw': f'https://raw.githubusercontent.com/{OWNER}/{RELREPO}/main/'
                            f'apk/{a.version_name}/{dst}'})
        facts[dst] = {'size': os.path.getsize(d), 'sha256': sha(d)}
        print(f'  ✓ {abi}: vc={measured}(实测) size={os.path.getsize(d)}')

    # 3) 分片（arm64 主包，15MiB 一片，与 1.5.1 同构）
    size = os.path.getsize(arm64)
    n = (size + PART - 1) // PART
    parts = []
    with open(arm64, 'rb') as f:
        for i in range(n):
            f.seek(i * PART)
            blob = f.read(PART)
            p = os.path.join(a.out, 'parts', f'apk.part{i}')
            open(p, 'wb').write(blob)
            parts.append({'file': f'apk.part{i}', 'size': len(blob),
                          'sha256': hashlib.sha256(blob).hexdigest()})
    # 分片拼回去必须与整包逐字节同哈希，否则上传的是两套东西
    h = hashlib.sha256()
    for p in parts:
        h.update(open(os.path.join(a.out, 'parts', p['file']), 'rb').read())
    if h.hexdigest() != facts['chunkspoke-latest.apk']['sha256']:
        raise SystemExit('[中止] 分片重组哈希 != 整包哈希')
    print(f'  ✓ {n} 个分片重组哈希与整包一致')

    json.dump({'versionName': a.version_name, 'baseVersionCode': a.base_code,
               'note': '应用内更新清单以 arm64 包为主；v7a/x86_64 为同版本生产包，'
                       'versionCode 依 Flutter split-per-abi 规则分别 +1000/+2000/+4000，'
                       '供对应 ABI 侧载或后续分发使用。',
               'packages': pkgs},
              open(os.path.join(a.out, 'abi-manifest.json'), 'w', encoding='utf-8', newline=LF),
              ensure_ascii=False, indent=2)
    json.dump({'packages': facts, 'parts': parts},
              open(os.path.join(a.out, 'facts.json'), 'w', encoding='utf-8', newline=LF),
              ensure_ascii=False, indent=2)

    # 4) 包内清单 vs 线上清单：除自指指纹外必须逐字段同值
    packed = json.load(open(os.path.join(ROOT, 'assets', 'version.json'), encoding='utf-8'))
    online = json.load(open(os.path.join(a.out, 'version.json'), encoding='utf-8'))
    same = all(packed.get(k) == online.get(k)
               for k in ('versionName', 'versionCode', 'url', 'urls', 'pageUrl', 'notes'))
    print(f'  包内/线上清单非自指字段同值 = {same}')
    print(f'  自指指纹（必然滞后一次构建）：包内 {packed["sha256"][:12]}…/{packed["size"]} '
          f'vs 线上 {online["sha256"][:12]}…/{online["size"]}')
    if not same:
        raise SystemExit('[中止] 包内清单与线上清单不一致（非自指字段），发版前必须修平')
    print(f'== 装配完成：{a.out} ==')
    return 0


if __name__ == '__main__':
    sys.exit(main())
