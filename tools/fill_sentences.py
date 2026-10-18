#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""补全 level.sentences（句子闯关 / 块拼句用的多块目标句）。

策略（零语法风险，复用已有精选内容）：
- 对每个场景，若其词块自带 `sentence.text`（475/487 都有），直接用该例句作为目标句；
  并扫描同一场景内其他词块的 text 是否出现在该例句里 → 一并计入 chunkIds，
  形成真实「句子 = 词块组合」（而非机械拼接）。
- 少数没有例句的词块（A 场景旧 schema）用词块自身文本兜底；
  A 场景已有 14 条人工句子，保留原句，仅对未覆盖词块补单块句。
- 不做任何新的英文创作，避免出现 "Excuse me thank you" 这类不成立拼接。

用法：
  python tools/fill_sentences.py --dry-run   # 只看统计，不写
  python tools/fill_sentences.py             # 写回 assets/content_pack.json
"""
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
PACK = os.path.normpath(os.path.join(HERE, "..", "assets", "content_pack.json"))


def norm(s):
    return re.sub(r"\s+", " ", (s or "").lower()).strip()


# A 场景为旧 schema（词块无例句），且旧句含机械拼接（"Excuse me thank you"），
# 这里手写 12 条自然句替换，保证语用成立且覆盖 A 全部 12 个词块。
MANUAL = {
    "A": [
        ("Good morning, everyone.", "大家早上好", ["a01", "a11"]),
        ("Good evening, everyone.", "大家晚上好", ["a02", "a11"]),
        ("I'm fine, thank you.", "我很好，谢谢", ["a03", "a04"]),
        ("Thank you so much.", "非常感谢", ["a04"]),
        ("My name is Lily.", "我叫莉莉", ["a05"]),
        ("What's your name, please?", "请问你叫什么名字", ["a06"]),
        ("Nice to meet you, too.", "我也很高兴认识你", ["a07"]),
        ("See you tomorrow.", "明天见", ["a08", "a12"]),
        ("Take care, everyone.", "大家保重", ["a09", "a11"]),
        ("Excuse me, please.", "不好意思，打扰一下", ["a10"]),
        ("Nice to meet you, everyone.", "很高兴认识大家", ["a07", "a11"]),
        ("See you again, everyone.", "大家回头见", ["a08", "a11"]),
    ]
}


def covered_ids(sentences):
    out = set()
    for s in sentences or []:
        for cid in s.get("chunkIds") or []:
            out.add(cid)
    return out


def build_for_level(L):
    """返回该场景新的 sentences 列表。"""
    chunks = L.get("chunks", [])
    existing = L.get("sentences") or []
    by_id = {c["id"]: c for c in chunks}

    # 手写覆盖（A 场景）：校验 chunkIds 均存在，防止悬空引用。
    if L["id"] in MANUAL:
        out = []
        for i, (text, cn, ids) in enumerate(MANUAL[L["id"]], start=1):
            assert all(cid in by_id for cid in ids), f"manual bad id in {L['id']}: {ids}"
            out.append({
                "id": f"{L['id'].lower()}_s{i:02d}",
                "text": text,
                "meaningCN": cn,
                "chunkIds": ids,
            })
        return out
    has_example = any(
        isinstance(c.get("sentence"), dict) and c["sentence"].get("text")
        for c in chunks
    )
    out = []
    seq = 0

    def mkid():
        nonlocal seq
        seq += 1
        return f"{L['id'].lower()}_s{seq:02d}"

    if has_example:
        # 以每块自带的精选例句为骨架，生成句子（含多块组合识别）。
        for c in chunks:
            ex = None
            if isinstance(c.get("sentence"), dict):
                ex = c["sentence"].get("text")
            if not ex:
                ex = c.get("text", "")
            ex = ex.strip()
            if not ex:
                continue
            low = ex.lower()
            # 自身块必须包含（其例句一定含它）；按其在句中的位置开始切分。
            self_t = norm(c["text"]) or norm(ex)
            sp = low.find(self_t)
            if sp < 0:
                sp = 0
            spans = [(sp, sp + len(self_t), c["id"])]
            # 仅纳入与已选区间「不重叠」的其他词块，保证词块是对句子的干净切分；
            # 最终按出现位置排序 → chunkIds 顺序与句子语序一致（块拼句槽位才正确）。
            for o in chunks:
                if o["id"] == c["id"]:
                    continue
                t = norm(o["text"])
                if not t:
                    continue
                p = low.find(t)
                if p < 0:
                    continue
                e = p + len(t)
                if any(not (e <= s or p >= en) for (s, en, _id) in spans):
                    continue
                spans.append((p, e, o["id"]))
            spans.sort(key=lambda x: x[0])
            ids = [cid for (_s, _e, cid) in spans]
            out.append({
                "id": mkid(),
                "text": ex,
                "meaningCN": c.get("meaningCN", ""),
                "chunkIds": ids,
            })
    else:
        # 旧 schema（A）：保留已有句子，仅补未覆盖词块。
        out = [dict(s) for s in existing]
        covered = covered_ids(out)
        for c in chunks:
            if c["id"] in covered:
                continue
            out.append({
                "id": mkid(),
                "text": c.get("text", "").strip(),
                "meaningCN": c.get("meaningCN", ""),
                "chunkIds": [c["id"]],
            })
    return out


def main():
    dry = "--dry-run" in sys.argv
    d = json.load(open(PACK, encoding="utf-8"))
    total = 0
    unreferenced = 0
    combos = 0
    print(f"version={d.get('version')} levels={len(d['levels'])}")
    for L in d["levels"]:
        before = len(L.get("sentences") or [])
        new = build_for_level(L)
        total += len(new)
        covered = covered_ids(new)
        miss = [c["id"] for c in L["chunks"] if c["id"] not in covered]
        unreferenced += len(miss)
        lc = sum(1 for s in new if len(s["chunkIds"]) > 1)
        combos += lc
        print(f"{L['id']:>2} {L['theme'][:20]:<20} sentences {before:>2} -> {len(new):>2} "
              f"(multi-chunk={lc}, uncovered={len(miss)})")
        if not dry:
            L["sentences"] = new

    print(f"TOTAL generated={total} multi-chunk={combos} uncovered_chunks={unreferenced}")
    if unreferenced:
        print("WARN: some chunks still uncovered")
    if dry:
        print("[dry-run] no file written")
        return
    d["version"] = "1.1.1"
    with open(PACK, "w", encoding="utf-8") as f:
        json.dump(d, f, ensure_ascii=False, indent=1)
        f.write("\n")
    # 立即回读校验 JSON 合法 + 计数
    back = json.load(open(PACK, encoding="utf-8"))
    assert len(back["levels"]) == 20, "level count changed"
    print(f"[OK] wrote {PACK} (version={back['version']})")


if __name__ == "__main__":
    main()
