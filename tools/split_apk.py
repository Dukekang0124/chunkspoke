#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把 arm64 release APK 复制为交付名并切分成 ≤15MiB 分块（供 jsDelivr 分块续传）。

用法（在 chunkspoke-flutter/ 下执行）：
  python tools/split_apk.py
"""
import os
import shutil
import sys

try:
    if hasattr(sys.stdout, 'reconfigure'):
        sys.stdout.reconfigure(encoding='utf-8')
except Exception:
    pass

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))  # tools/ -> flutter 根
DIST = os.path.join(os.path.dirname(ROOT), 'dist')
SRC = os.path.join(ROOT, 'build', 'app', 'outputs', 'flutter-apk',
                   'app-arm64-v8a-release.apk')
CHUNK = 15 * 1024 * 1024  # 15 MiB


def main():
    if not os.path.isfile(SRC):
        raise SystemExit(f'[split-apk] APK 不存在：{SRC}')

    full = os.path.join(DIST, 'chunkspoke-v1.4.2-preview18.apk')
    shutil.copy2(SRC, full)
    print(f'  全量 APK -> {full} ({os.path.getsize(full)} B)')

    outdir = os.path.join(DIST, 'apk', '1.4.2', 'parts')
    os.makedirs(outdir, exist_ok=True)
    with open(SRC, 'rb') as f:
        i = 0
        while True:
            b = f.read(CHUNK)
            if not b:
                break
            p = os.path.join(outdir, f'apk.part{i}')
            with open(p, 'wb') as o:
                o.write(b)
            print(f'  {os.path.basename(p)}: {len(b)} B')
            i += 1


if __name__ == '__main__':
    main()
