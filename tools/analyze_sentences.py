#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""分析 assets/content_pack.json 的目标句覆盖与中文质量（只读）。"""
import json
import os

HERE = os.path.dirname(os.path.abspath(__file__))
PACK = os.path.normpath(os.path.join(HERE, "..", "assets", "content_pack.json"))


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


if __name__ == "__main__":
    main()
