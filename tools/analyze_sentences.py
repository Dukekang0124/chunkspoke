#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""分析 assets/content_pack.json 的目标句覆盖与中文质量（只读）。"""
import json
import os
import re

HERE = os.path.dirname(os.path.abspath(__file__))
PACK = os.path.normpath(os.path.join(HERE, "..", "assets", "content_pack.json"))


def norm_surface(text):
    """与 Dart 侧 _normSurface 同口径：小写 + 只保留 [a-z0-9' ] 后去空白。"""
    return re.sub(r"[^a-z0-9' ]+", "", (text or "").lower()).strip()


def duplicate_surfaces(levels):
    """重复表面形态分组（沙盒合并成一枚 chip，内容侧只警告不阻断）。"""
    seen = {}
    for level in levels:
        for chunk in level.get("chunks", []):
            seen.setdefault(norm_surface(chunk.get("text")), []).append(
                f"{level['id']}/{chunk['id']}"
            )
    return sorted((k, v) for k, v in seen.items() if len(v) > 1)


def main():
    d = json.load(open(PACK, encoding="utf-8"))
    total_chunks = 0
    total_sent = 0
    total_fffd = 0
    total_withsent = 0
    print(f"version={d.get('version')} levels={len(d['levels'])}")
    for L in d["levels"]:
        cs = L.get("chunks", [])
        withsent = sum(
            1
            for c in cs
            if isinstance(c.get("sentence"), dict) and c["sentence"].get("text")
        )
        ss = len(L.get("sentences") or [])
        bad = sum(1 for c in cs if "\ufffd" in (c.get("meaningCN") or ""))
        bad_sent = sum(
            1
            for s in (L.get("sentences") or [])
            if "\ufffd" in (s.get("meaningCN") or "")
        )
        total_chunks += len(cs)
        total_sent += ss
        total_fffd += bad + bad_sent
        total_withsent += withsent
        print(
            f"{L['id']:>2} {L['theme'][:20]:<20} chunks={len(cs):>2} "
            f"chunk.sentence={withsent:>2} level.sentences={ss:>2} "
            f"mojibake(chunk/sent)={bad}/{bad_sent}"
        )
    print(
        f"TOTAL chunks={total_chunks} chunk.sentence={total_withsent} "
        f"level.sentences={total_sent} mojibake={total_fffd}"
    )
    dups = duplicate_surfaces(d["levels"])
    if not dups:
        print("DUPLICATE_SURFACE 无重复表面形态")
    else:
        print(f"DUPLICATE_SURFACE 警告 {len(dups)} 组（不阻断；沙盒会合并为一枚 chip）")
        for key, ids in dups:
            print(f"  「{key}」x{len(ids)}: {', '.join(ids)}")


if __name__ == "__main__":
    main()
