#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""ASR-191 · 自打包增强识别模型（sherpa-onnx zipformer 20M int8）并生成清单段。

为什么自己打包：`version.json` 的 `size/sha256/parts` 描述的是**我们自己的 zip**，
上游 HuggingFace 的 LFS sha 是逐文件、逐对象的，两者不可混用。本脚本：
  1. 只取 int8 四件（encoder/decoder/joiner/tokens），fp32 与测试音频一律不发；
  2. 打成**确定性 zip**（固定时间戳、固定顺序），顶层目录 = 清单 name；
  3. 按 15 MiB 切分片，逐片现算 sha256/size，整包现算 sha256/size；
  4. 输出可直接并入 `assets/version.json` 的 `asrModel` 段。

严禁直连 huggingface.co：清单 URL 只指向自家 releases 仓库的 CDN/raw/Pages 三源。

用法：
  python tools/pack_asr_model.py \
      --src D:/tmp/spike/models/sherpa-onnx-streaming-zipformer-en-20M-2023-02-17 \
      --out D:/gtmp/rel161 --tag asr-20m-2023-02-17 \
      [--write-assets]
"""
import argparse
import hashlib
import json
import os
import sys
import zipfile

LF = chr(10)
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OWNER = 'Dukekang0124'
RELREPO = 'chunkspoke-releases'
PART = 15728640  # 15 MiB，与 APK/发音包分片口径一致
NAME = 'sherpa-onnx-streaming-zipformer-en-20M-2023-02-17'
MODEL_VERSION = '2023-02-17-int8'


def sha256_file(path, start=0, length=None):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        f.seek(start)
        remaining = length if length is not None else os.path.getsize(path) - start
        while remaining > 0:
            chunk = f.read(min(1024 * 1024, remaining))
            if not chunk:
                break
            h.update(chunk)
            remaining -= len(chunk)
    return h.hexdigest()


def pick(src, prefix):
    """只挑 int8 主干文件；fp32 绝不进包（体积翻倍且无收益）。"""
    names = sorted(
        n for n in os.listdir(src)
        if n.startswith(prefix) and n.endswith('.int8.onnx')
    )
    if not names:
        raise SystemExit(f'[asr] {src} 缺少 {prefix}*.int8.onnx')
    return os.path.join(src, names[0])


def build_zip(src, zip_path, name):
    encoder = pick(src, 'encoder')
    decoder = pick(src, 'decoder')
    joiner = pick(src, 'joiner')
    tokens = os.path.join(src, 'tokens.txt')
    if not os.path.isfile(tokens):
        raise SystemExit(f'[asr] {src} 缺少 tokens.txt')
    files = [encoder, decoder, joiner, tokens]

    # 确定性：固定时间戳 + 固定顺序，同一输入重跑得到同一 zip。
    with zipfile.ZipFile(zip_path, 'w', zipfile.ZIP_DEFLATED, compresslevel=9) as z:
        for p in files:
            info = zipfile.ZipInfo(f'{name}/{os.path.basename(p)}', (1980, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o644 << 16
            with open(p, 'rb') as f:
                z.writestr(info, f.read())
    return files


def split_parts(zip_path, parts_dir):
    os.makedirs(parts_dir, exist_ok=True)
    size = os.path.getsize(zip_path)
    n = (size + PART - 1) // PART
    out = []
    with open(zip_path, 'rb') as f:
        for i in range(n):
            off = i * PART
            ln = min(PART, size - off)
            f.seek(off)
            data = f.read(ln)
            p = os.path.join(parts_dir, f'asr.part{i}')
            with open(p, 'wb') as w:
                w.write(data)
            out.append({'path': p, 'size': ln, 'sha256': sha256_file(p)})
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--src', required=True, help='本地 20M int8 模型目录')
    ap.add_argument('--out', required=True, help='releases 装配目录（如 D:/gtmp/rel161）')
    ap.add_argument('--tag', default='asr-20m-2023-02-17')
    ap.add_argument('--name', default=NAME)
    ap.add_argument('--model-version', default=MODEL_VERSION)
    ap.add_argument('--write-assets', action='store_true')
    a = ap.parse_args()

    base = os.path.join(a.out, 'models', a.tag)
    os.makedirs(base, exist_ok=True)
    zip_path = os.path.join(base, f'{a.name}.zip')
    files = build_zip(a.src, zip_path, a.name)
    parts = split_parts(zip_path, os.path.join(base, 'parts'))

    whole_size = os.path.getsize(zip_path)
    whole_sha = sha256_file(zip_path)
    assert sum(p['size'] for p in parts) == whole_size, '分片长度之和 != 整包'

    cdn = f'https://cdn.jsdelivr.net/gh/{OWNER}/{RELREPO}@main/models/{a.tag}/parts'
    raw = f'https://raw.githubusercontent.com/{OWNER}/{RELREPO}/main/models/{a.tag}/parts'
    pages = f'https://dukekang0124.github.io/{RELREPO}/models/{a.tag}/parts'
    m = {
        'name': a.name,
        'modelVersion': a.model_version,
        'sha256': whole_sha,
        'size': whole_size,
        'parts': [
            {
                'url': f'{cdn}/asr.part{i}',
                'size': p['size'],
                'sha256': p['sha256'],
                'fallbacks': [f'{raw}/asr.part{i}', f'{pages}/asr.part{i}'],
            }
            for i, p in enumerate(parts)
        ],
        'mirrorUrl': f'https://raw.githubusercontent.com/{OWNER}/{RELREPO}/main/models/{a.tag}/{a.name}.zip',
        'license': 'Apache-2.0',
        'source': 'k2-fsa/sherpa-onnx (asr-models release), 20M tier',
    }

    print(f'[asr] 源文件（只发 int8 四件）：')
    for p in files:
        print(f'  {os.path.basename(p)}  {os.path.getsize(p)} B  {sha256_file(p)[:16]}…')
    print(f'[asr] zip  {whole_size} B  {whole_sha}')
    for i, p in enumerate(parts):
        print(f'  part{i}  {p["size"]} B  {p["sha256"][:16]}…')
    print(f'[asr] 合计 {whole_size} B = {whole_size/1e6:.2f} MB / {whole_size/1048576:.2f} MiB')

    block = json.dumps(m, ensure_ascii=False, indent=2) + LF
    out_json = os.path.join(base, 'asrModel.json')
    open(out_json, 'w', encoding='utf-8', newline=LF).write(block)
    print(f'[asr] 清单段：{out_json}')

    if a.write_assets:
        p = os.path.join(ROOT, 'assets', 'version.json')
        tpl = json.load(open(p, encoding='utf-8'))
        tpl['asrModel'] = m
        open(p, 'w', encoding='utf-8', newline=LF).write(
            json.dumps(tpl, ensure_ascii=False, indent=2) + LF)
        print(f'[asr] 已写入 {p} 的 asrModel 段')
    return 0


if __name__ == '__main__':
    sys.exit(main())
