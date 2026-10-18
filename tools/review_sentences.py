#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""生成全量目标句审校清单（Markdown），供人工抽查。

输出：../../11-产品规划/2026-10-17-ChunkSpoke-内容审校清单-v1.2.7.md
"""
import json
import os
import re

HERE = os.path.dirname(os.path.abspath(__file__))
PACK = os.path.normpath(os.path.join(HERE, "..", "assets", "content_pack.json"))
OUT = os.path.normpath(
    os.path.join(
        HERE, "..", "..", "11-产品规划",
        "2026-10-17-ChunkSpoke-内容审校清单-v1.2.7.md",
    )
)

HANDWRITTEN = {"A"}  # A 场景为人工手写，重点核对语用


def main():
    d = json.load(open(PACK, encoding="utf-8"))
    lines = []
    total = 0
    flags = []
    lines.append("# ChunkSpoke 目标句审校清单（v1.2.7 / content 1.1.1）\n")
    lines.append(
        "> 生成方式：`tools/fill_sentences.py`。绝大多数句来自词块精选例句；"
        "组合块由例句中真实出现的其他词块自动识别。A 场景为人工手写。\n"
    )
    lines.append(
        "> 审校要点：① 组合块顺序是否与句子语序一致；② 中文释义是否贴合整句；"
        "③ 是否出现同场景重复句；④ 是否存在过短/不成句。\n"
    )

    for L in d["levels"]:
        sents = L.get("sentences") or []
        ids = {c["id"] for c in L["chunks"]}
        text2id = {c["text"]: c["id"] for c in L["chunks"]}
        lines.append(
            f"\n## {L['id']} · {L['theme']}　（{len(L['chunks'])} 块 / {len(sents)} 句）\n"
        )
        lines.append("| # | 目标句 | 中文 | 组合词块 | 标记 |")
        lines.append("|---|---|---|---|---|")
        seen = {}
        for i, s in enumerate(sents, 1):
            text = (s.get("text") or "").strip()
            cn = s.get("meaningCN") or ""
            cids = s.get("chunkIds") or []
            marks = []
            total += 1
            # 悬空引用
            if any(cid not in ids for cid in cids):
                marks.append("⚠悬空ID")
                flags.append(f"{L['id']} #{i} 引用不存在的块：{cids}")
            # 重复句
            key = re.sub(r"\s+", " ", text.lower())
            if key in seen:
                marks.append("⚠重复")
                flags.append(f"{L['id']} #{i} 与 #{seen[key]} 重复：{text}")
            else:
                seen[key] = i
            # 过短
            if len(text.split()) <= 2:
                marks.append("⚠过短")
                flags.append(f"{L['id']} #{i} 过短：{text}")
            # 中文为空
            if not cn.strip():
                marks.append("⚠无中文")
            # 组合
            if len(cids) > 1:
                marks.append("组合")
            if L["id"] in HANDWRITTEN:
                marks.append("手写")
            combo = " + ".join(cids)
            lines.append(
                f"| {i} | {text} | {cn} | {combo} | {' '.join(marks)} |"
            )

    # 汇总
    head = []
    head.append(f"\n---\n\n**合计：{total} 句，待关注 {len(flags)} 条。**\n")
    if flags:
        head.append("\n### 需人工重点确认\n")
        for f in flags:
            head.append(f"- {f}")
        head.append("")
    content = "\n".join(lines) + "\n" + "\n".join(head) + "\n"

    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "w", encoding="utf-8") as f:
        f.write(content)
    print(f"total sentences: {total}")
    print(f"flagged: {len(flags)}")
    print(f"written: {OUT}")
    for f in flags[:10]:
        print("  ", f)


if __name__ == "__main__":
    main()
