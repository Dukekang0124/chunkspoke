#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把随包 Vosk 模型 zip 切分成 ≤15MiB 分块，输出真值 sha256/size。

v1.4.2 模型外移：模型不再打进 APK，改为首启分块下载（复用 partPlan 续传）。
本脚本只读 assets 里的模型、切块、算哈希，不改动模型本身，也不改构建产物。
产物落在仓库根 dist/models/ 下，供上传 chunkspoke-releases 后走 jsDelivr 托管。

用法（在 chunkspoke-flutter/ 下执行）：
  python tools/split_model.py
"""
import hashlib
import json
import os
import sys
import zipfile

try:
    if hasattr(sys.stdout, 'reconfigure'):
        sys.stdout.reconfigure(encoding='utf-8')
except Exception:
    pass

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))  # tools/ -> flutter 根
SRC = os.path.join(ROOT, 'assets', 'vosk-model-small-en-us-0.15.zip')
CHUNK = 15 * 1024 * 1024  # 15728640 B = 15 MiB
OUT = os.path.join(os.path.dirname(ROOT), 'dist', 'models',
                   'vosk-model-small-en-us-0.15', 'parts')


def main():
    if not os.path.isfile(SRC):
        raise SystemExit(f'[split] 模型不存在：{SRC}')

    full_sha = hashlib.sha256()
    size = 0
    with open(SRC, 'rb') as f:
        while True:
            b = f.read(1024 * 1024)
            if not b:
                break
            full_sha.update(b)
            size += len(b)

    with zipfile.ZipFile(SRC) as z:
        top = sorted({n.split('/')[0] for n in z.namelist()})

    os.makedirs(OUT, exist_ok=True)
    parts = []
    with open(SRC, 'rb') as f:
        idx = 0
        while True:
            b = f.read(CHUNK)
            if not b:
                break
            p = os.path.join(OUT, f'model.part{idx}')
            with open(p, 'wb') as o:
                o.write(b)
            parts.append({
                'file': f'model.part{idx}',
                'size': len(b),
                'sha256': hashlib.sha256(b).hexdigest(),
            })
            idx += 1

    print(json.dumps({
        'name': 'vosk-model-small-en-us-0.15',
        'modelVersion': '0.15',
        'size': size,
        'sha256': full_sha.hexdigest(),
        'zip_top_entries': top,
        'parts': parts,
    }, ensure_ascii=False, indent=2))
    print(f'  (分块已写入 {OUT})')


if __name__ == '__main__':
    main()
