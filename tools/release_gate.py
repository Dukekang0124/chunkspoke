#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""ASR-205/206 发版门禁：不变量测试 + 自检归档零红 + 签名指纹一致，缺一不发。

用法（本地 / CI 同一套判据）：
  python tools/release_gate.py --version-name 1.7.3 --version-code 4073 --apk build/.../app-arm64-v8a-release.apk
  python tools/release_gate.py --skip-tests        # CI 已跑过测试时复用

判定：
  1) flutter test test/progress_invariant_test.dart 必须全过
     （1000 组随机序列 + 全部台账写入点各一条：六步/复习/跳过/导入/迁移重置/开口失败/一键修复）；
  2) release/selfcheck/ 下必须有自检归档（默认取最新；给了 --version-name 则必须同名），
     且 needsAction=false、reds=[]、audits 非空。
  3) 待发布 APK 的签名证书 SHA-256 必须 == release/signing/previous-online-cert.txt 的
     certSha256（ASR-206 §三：防换签打断全量用户的覆盖安装）。
  任一不满足 → 退出码 1，禁止 bump 清单/上传/发布。

为什么不看 allGreen：错块留痕与「未下载可选语音包」属于提示项（见 SelfCheckReport），
发版闸门只认硬红名单（陈旧断点）与硬失败。
"""
import argparse
import glob
import hashlib
import json
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SELFCHECK_DIR = os.path.join(ROOT, 'release', 'selfcheck')
SIGN_BASELINE = os.path.join(ROOT, 'release', 'signing', 'previous-online-cert.txt')

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
    print('== 闸 1/3 不变量测试（1000 组随机序列 + 写入点矩阵）==')
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
    print(f'== 闸 2/3 自检归档：{os.path.relpath(path, ROOT)} ==')
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


def read_sign_baseline():
    if not os.path.isfile(SIGN_BASELINE):
        die(f'缺少签名基线：{SIGN_BASELINE}（第四闸无法判定，禁止发布）')
    base = {}
    for line in open(SIGN_BASELINE, encoding='utf-8'):
        line = line.strip()
        if not line or line.startswith('#') or '=' not in line:
            continue
        k, v = line.split('=', 1)
        base[k.strip()] = v.strip()
    if not base.get('certSha256'):
        die('签名基线里没有 certSha256，第四闸无法判定')
    return base


def find_apksigner():
    exe = 'apksigner.bat' if os.name == 'nt' else 'apksigner'
    roots = [os.environ.get('ANDROID_SDK_ROOT') or r'D:\tools\android-sdk',
             os.environ.get('ANDROID_HOME') or '']
    for b in roots:
        bt = os.path.join(b, 'build-tools') if b else ''
        if not os.path.isdir(bt):
            continue
        for v in sorted(os.listdir(bt), reverse=True):
            c = os.path.join(bt, v, exe)
            if os.path.isfile(c):
                return c
    return None


def cert_sha256_of(apk):
    tool = find_apksigner()
    if not tool:
        die('找不到 apksigner（设 ANDROID_SDK_ROOT 或 D:\\tools\\android-sdk），第四闸无法判定')
    r = subprocess.run([tool, 'verify', '--print-certs', apk],
                       capture_output=True, text=True)
    out = (r.stdout or '') + (r.stderr or '')
    m = re.search(r'certificate SHA-256 digest:\s*([0-9a-fA-F]{64})', out)
    if not m:
        die(f'apksigner 未吐出证书指纹，第四闸无法判定：{out.strip()[:200]}')
    return m.group(1).lower()


def check_signing(apk):
    base = read_sign_baseline()
    if not apk:
        print('== 闸 3/3 签名指纹：未传 --apk，本闸跳过（出包/发布路径必须传）==')
        return
    print(f'== 闸 3/3 签名指纹：{os.path.basename(apk)} ==')
    if not os.path.isfile(apk):
        die(f'待发布 APK 不存在：{apk}')
    got = cert_sha256_of(apk)
    want = base['certSha256'].lower()
    if got != want:
        die('签名指纹与上一线上版本不一致 → 换签会打断全量用户覆盖安装（进度只存本机，'
            f'等于丢进度）。期望 {want}（{base.get("versionName")}），实得 {got}。'
            '如确需换签，先出迁移方案单并另行拍板。')
    size = os.path.getsize(apk)
    h = hashlib.sha256()
    with open(apk, 'rb') as f:
        for chunk in iter(lambda: f.read(1 << 20), b''):
            h.update(chunk)
    print(f'  ✓ 证书 SHA-256 {got[:16]}… == 线上 {base.get("versionName")} 同款'
          f'（{base.get("certSubject", "")}）· apk sha {h.hexdigest()[:16]}… · {size}B')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--version-name', help='目标版本名，如 1.7.3（同时校验归档版本）')
    ap.add_argument('--version-code', type=int, help='目标 versionCode（arm64 槽位），如 4073')
    ap.add_argument('--selfcheck', help='指定归档 JSON（默认取 release/selfcheck 下最新/同名）')
    ap.add_argument('--skip-tests', action='store_true', help='CI 已跑过全量测试时复用')
    ap.add_argument('--apk', help='待发布 arm64 APK 路径（第四闸：比对签名证书指纹）')
    a = ap.parse_args()

    if not a.skip_tests:
        run_invariant_tests()
    path = a.selfcheck or pick_archive(a.version_name)
    check_archive(path, a.version_name, a.version_code)
    check_signing(a.apk)
    print('[门禁通过] 允许 bump 清单并进入发布序列')


if __name__ == '__main__':
    main()
