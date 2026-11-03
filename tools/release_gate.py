#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""ASR-205 发版门禁：不变量测试 + 自检归档零红，缺一不发。

用法（本地 / CI 同一套判据）：
  python tools/release_gate.py --version-name 1.7.3 --version-code 4073
  python tools/release_gate.py --skip-tests        # CI 已跑过测试时复用

判定：
  1) flutter test test/progress_invariant_test.dart 必须全过（1000 组随机序列）；
  2) release/selfcheck/ 下必须有自检归档（默认取最新；给了 --version-name 则必须同名），
     且 needsAction=false、reds=[]、audits 非空。
  任一不满足 → 退出码 1，禁止 bump 清单/上传/发布。

为什么不看 allGreen：错块留痕与「未下载可选语音包」属于提示项（见 SelfCheckReport），
发版闸门只认硬红名单（陈旧断点）与硬失败。
"""
import argparse
import glob
import json
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SELFCHECK_DIR = os.path.join(ROOT, 'release', 'selfcheck')

# Windows 控制台默认 GBK，打印 ✓/中文会被编码错误打断；统一按 UTF-8 输出。
for _s in (sys.stdout, sys.stderr):
    try:
        _s.reconfigure(encoding='utf-8', errors='replace')
    except Exception:
        pass


def die(msg):
    print(f'[门禁不通过] {msg}', file=sys.stderr)
    sys.exit(1)


def find_flutter():
    exe = 'flutter.bat' if os.name == 'nt' else 'flutter'
    for c in (
        os.environ.get('FLUTTER_ROOT') and os.path.join(os.environ['FLUTTER_ROOT'], 'bin', exe),
        os.path.join(r'D:\tools\flutter', 'bin', exe),
        exe,
    ):
        if c and (os.path.isabs(c) and os.path.isfile(c) or not os.path.isabs(c)):
            return c
    return exe


def run_invariant_tests():
    print('== 闸 1/2 不变量测试（1000 组随机序列）==')
    r = subprocess.run(
        [find_flutter(), 'test', 'test/progress_invariant_test.dart'],
        cwd=ROOT,
    )
    if r.returncode != 0:
        die('不变量测试未全过')
    print('  ✓ 不变量测试全过')


def pick_archive(version_name):
    if version_name:
        p = os.path.join(SELFCHECK_DIR, f'selfcheck-{version_name}.json')
        if not os.path.isfile(p):
            die(f'缺少本版自检归档：{p}（先跑 CS_SELFCHECK_ARCHIVE=1 flutter test '
                f'test/release_selfcheck_test.dart）')
        return p
    files = sorted(glob.glob(os.path.join(SELFCHECK_DIR, 'selfcheck-*.json')))
    if not files:
        die(f'缺少自检归档：{SELFCHECK_DIR}/selfcheck-*.json')
    return files[-1]


def check_archive(path, version_name, version_code):
    print(f'== 闸 2/2 自检归档：{os.path.relpath(path, ROOT)} ==')
    try:
        with open(path, encoding='utf-8') as f:
            d = json.load(f)
    except Exception as e:
        die(f'归档无法解析：{e}')

    reds = d.get('reds') or []
    audits = d.get('audits') or []
    if not audits:
        die('归档里没有模块审计（没扫到任何模块不算零红）')
    if reds:
        names = ', '.join(str(r.get('theme') or r.get('levelId')) for r in reds)
        die(f'自检红名单非空（{len(reds)}）：{names}')
    if d.get('needsAction') is not False:
        die(f"needsAction={d.get('needsAction')}，必须为 false")
    if version_name and str(d.get('localVersion')) != str(version_name):
        die(f"归档版本 {d.get('localVersion')} != 目标 {version_name}")
    if version_code and int(d.get('localVersionCode') or 0) != int(version_code):
        die(f"归档 versionCode {d.get('localVersionCode')} != 目标 {version_code}")

    bad = [a for a in audits if not a.get('consistent', False)]
    if bad:
        die(f'仍有不同位模块：{len(bad)}')
    print(f"  ✓ {len(audits)} 个模块零红 · hints={d.get('hints')} · "
          f"v{d.get('localVersion')}/{d.get('localVersionCode')}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--version-name', help='目标版本名，如 1.7.3（同时校验归档版本）')
    ap.add_argument('--version-code', type=int, help='目标 versionCode（arm64 槽位），如 4073')
    ap.add_argument('--selfcheck', help='指定归档 JSON（默认取 release/selfcheck 下最新/同名）')
    ap.add_argument('--skip-tests', action='store_true', help='CI 已跑过全量测试时复用')
    a = ap.parse_args()

    if not a.skip_tests:
        run_invariant_tests()
    path = a.selfcheck or pick_archive(a.version_name)
    check_archive(path, a.version_name, a.version_code)
    print('[门禁通过] 允许 bump 清单并进入发布序列')


if __name__ == '__main__':
    main()
