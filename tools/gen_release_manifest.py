#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""生成本次发版的版本清单（apk 指纹 + 15MiB 分片），并可写回包内 assets/version.json。

为什么要它：v1.4.4 那次「清单 url 指向没上传的资产」把官网下载按钮和应用内兜底一起打空，
v1.5.1 又出现「包内 assets/version.json 滞后两个版本」。本脚本把指纹与分片一次算全，
包内副本与线上副本由同一份代码产出，杜绝手抄。

自引用说明（必须知道再使用）：清单里的 sha256/size/parts 描述的是「某个具体 apk」，
而这份清单本身又被打进 apk —— 数学上不可能让包内那一份描述它自己。
约定：包内副本描述上一次构建（pass A），线上副本描述最终产物（pass B）。
两副本除 sha256/size/parts 外逐字段同值，SOP 要求把这条等式测出来。

用法：
  python tools/gen_release_manifest.py --apk <path> --version-name 1.5.2 --version-code 4053 \
      --notes "..." --template assets/version.json [--write-assets] [--out out.json]
"""
import argparse
import hashlib
import json
import os
import sys

LF = chr(10)  # 强制 LF：git 会把 CRLF 归一化，本地/远端要逐字节可比

try:
    if hasattr(sys.stdout, 'reconfigure'):
        sys.stdout.reconfigure(encoding='utf-8')
except Exception:
    pass

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OWNER = 'Dukekang0124'
RELREPO = 'chunkspoke-releases'
PART = 15728640  # 15 MiB：jsDelivr/GitHub Pages 单文件舒适区，且与 1.5.1 结构一致


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


def build_parts(apk, tag):
    """与 1.5.1 逐字段同构（url/size/sha256，url 指 jsDelivr@main）——
    结构不变才能复用上一版的 403 回退实测结论。"""
    size = os.path.getsize(apk)
    n = (size + PART - 1) // PART
    parts = []
    for i in range(n):
        off = i * PART
        ln = min(PART, size - off)
        parts.append({
            'url': f'https://cdn.jsdelivr.net/gh/{OWNER}/{RELREPO}@main/'
                   f'apk/{tag}/parts/apk.part{i}',
            'size': ln,
            'sha256': sha256_file(apk, off, ln),
        })
    return parts


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--apk', required=True)
    ap.add_argument('--version-name', required=True)
    ap.add_argument('--version-code', type=int, required=True)
    ap.add_argument('--notes', required=True)
    ap.add_argument('--template', default=os.path.join('assets', 'version.json'),
                    help='沿用其 model / voiceModel 块（发音包不随版本变，别手抄）')
    ap.add_argument('--write-assets', action='store_true',
                    help='把结果写回包内 assets/version.json')
    ap.add_argument('--out', help='另存一份线上清单')
    a = ap.parse_args()

    tpl = json.load(open(os.path.join(ROOT, a.template), encoding='utf-8'))
    tag = f'v{a.version_name}'
    pages = f'https://dukekang0124.github.io/{RELREPO}/apk/{a.version_name}/chunkspoke-latest.apk'
    raw = (f'https://raw.githubusercontent.com/{OWNER}/{RELREPO}/main/'
           f'apk/{a.version_name}/chunkspoke-latest.apk')
    m = {
        'versionName': a.version_name,
        'versionCode': a.version_code,
        'url': pages,
        'urls': [pages, raw],
        'pageUrl': tpl.get('pageUrl', 'https://dukekang0124.github.io/chunkspoke/'),
        'sha256': sha256_file(a.apk),
        'size': os.path.getsize(a.apk),
        'notes': a.notes,
        'parts': build_parts(a.apk, a.version_name),
    }
    for k in ('model', 'voiceModel'):
        if tpl.get(k):
            m[k] = tpl[k]

    text = json.dumps(m, ensure_ascii=False, indent=2) + '\n'
    if a.write_assets:
        p = os.path.join(ROOT, 'assets', 'version.json')
        open(p, 'w', encoding='utf-8', newline=LF).write(text)
        print(f'  ✓ 包内清单已写：{p}')
    if a.out:
        open(a.out, 'w', encoding='utf-8', newline=LF).write(text)
        print(f'  ✓ 线上清单已写：{a.out}')
    print(f'  {a.version_name}({a.version_code}) size={m["size"]} sha={m["sha256"][:16]}… '
          f'parts={len(m["parts"])}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
