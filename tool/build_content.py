#!/usr/bin/env python3
"""把 App 内容包压缩成网页版内容资产，并在生成时做硬校验。

用法：
    python tool/build_content.py [--src D:/cs_build/assets] [--out assets/content]

输出两个文件（提交进仓库，随 flutter build 打包）：
    assets/content/chunks.json    487 块
    assets/content/articles.json  24 篇

只保留网页版会用的字段；App 侧的六步句/combos 等字段不搬运。
任何数量、字段或引用不一致都直接失败退出，不生成半成品。
"""

import argparse
import hashlib
import json
import sys
from pathlib import Path

EXPECTED_CHUNKS = 487
EXPECTED_ARTICLES = 24

CHUNK_FIELDS = (
    "id",
    "text",
    "meaningCN",
    "semantic",
    "funcCat",
    "type",
    "freqRank",
    "sources",
    "tier",
)
ARTICLE_FIELDS = ("id", "title", "level", "sceneLabel", "summaryCN", "baseRate")
TIERS = ("T0", "T1", "T2")
LEVELS = tuple("ABCDEFGHIJKLMNOPQRST")


def fail(msg: str) -> None:
    print(f"内容校验失败：{msg}", file=sys.stderr)
    raise SystemExit(1)


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def load(path: Path) -> dict:
    if not path.is_file():
        fail(f"找不到 {path}")
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as e:
        fail(f"{path.name} 不是合法 JSON：{e}")


def build_chunks(pack: dict) -> dict:
    levels = pack.get("levels")
    if not isinstance(levels, list) or not levels:
        fail("content_pack.levels 缺失或为空")

    level_meta = []
    chunks = []
    examples = {}
    seen = set()

    for level in levels:
        lid = level.get("id")
        if lid not in LEVELS:
            fail(f"未知关卡 id：{lid!r}")
        level_meta.append({"id": lid, "theme": level.get("theme", "")})
        for s in level.get("sentences", []):
            for cid in s.get("chunkIds", []):
                examples.setdefault(cid, (s.get("text", ""), s.get("meaningCN", "")))
        for c in level.get("chunks", []):
            missing = [k for k in CHUNK_FIELDS if k not in c]
            if missing:
                fail(f"块 {c.get('id')!r} 缺字段 {missing}")
            cid = c["id"]
            if cid in seen:
                fail(f"块 id 重复：{cid}")
            seen.add(cid)
            if c["tier"] not in TIERS:
                fail(f"块 {cid} 的 tier 非法：{c['tier']!r}")
            if not isinstance(c["sources"], list):
                fail(f"块 {cid} 的 sources 必须是数组")
            ex, ex_cn = examples.get(cid, ("", ""))
            chunks.append(
                {
                    "id": cid,
                    "text": c["text"],
                    "meaningCN": c["meaningCN"],
                    "semantic": c["semantic"],
                    "funcCat": c["funcCat"],
                    "type": c["type"],
                    "freqRank": c["freqRank"],
                    "sources": c["sources"],
                    "tier": c["tier"],
                    "level": lid,
                    "example": ex,
                    "exampleCN": ex_cn,
                }
            )

    if len(chunks) != EXPECTED_CHUNKS:
        fail(f"块数量 {len(chunks)} != {EXPECTED_CHUNKS}")
    tiers = {t: sum(1 for c in chunks if c["tier"] == t) for t in TIERS}
    funcs = sorted({c["funcCat"] for c in chunks})
    return {
        "version": pack.get("version", ""),
        "count": len(chunks),
        "tiers": tiers,
        "funcCats": funcs,
        "levels": level_meta,
        "chunks": chunks,
    }


def build_articles(doc: dict, known_ids: set) -> dict:
    articles = doc.get("articles")
    if not isinstance(articles, list) or len(articles) != EXPECTED_ARTICLES:
        fail(f"文章数量 {len(articles or [])} != {EXPECTED_ARTICLES}")

    out = []
    seen = set()
    for a in articles:
        missing = [k for k in ARTICLE_FIELDS if k not in a]
        if missing:
            fail(f"文章 {a.get('id')!r} 缺字段 {missing}")
        aid = a["id"]
        if aid in seen:
            fail(f"文章 id 重复：{aid}")
        seen.add(aid)
        sentences = []
        for s in a.get("sentences", []):
            refs = []
            for ref in s.get("chunks", []):
                rid = ref.get("id")
                is_cand = bool(ref.get("candidate"))
                if rid not in known_ids:
                    # 候选块（lx_*）只存在于文章内，App 侧也只记「候选意愿」，不进词块库
                    if not is_cand or not str(rid).startswith("lx_"):
                        fail(f"文章 {aid} 句子 {s.get('id')} 引用未知块 {rid!r}")
                refs.append(
                    {
                        "id": rid,
                        "text": ref.get("text", ""),
                        "meaningCN": ref.get("meaningCN", ""),
                        "candidate": is_cand,
                    }
                )
            if not s.get("text"):
                fail(f"文章 {aid} 句子 {s.get('id')} 缺 text")
            sentences.append(
                {
                    "id": s["id"],
                    "text": s["text"],
                    "meaningCN": s.get("meaningCN", ""),
                    "chunks": refs,
                }
            )
        if not sentences:
            fail(f"文章 {aid} 没有句子")
        out.append(
            {
                "id": aid,
                "title": a["title"],
                "level": a["level"],
                "sceneLabel": a.get("sceneLabel", ""),
                "summaryCN": a.get("summaryCN", ""),
                "baseRate": a.get("baseRate", 1.0),
                "sentences": sentences,
            }
        )
    return {
        "version": doc.get("version", ""),
        "count": len(out),
        "sentenceCount": sum(len(a["sentences"]) for a in out),
        "articles": out,
    }


def dump(path: Path, payload: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    text = json.dumps(payload, ensure_ascii=False, separators=(",", ":"))
    path.write_text(text, encoding="utf-8")
    raw = path.stat().st_size
    print(f"{path.as_posix()}  {raw} B  sha256={sha256(path)}")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--src", default="D:/cs_build/assets")
    ap.add_argument("--out", default="assets/content")
    args = ap.parse_args()

    src = Path(args.src)
    out = Path(args.out)
    pack_path = src / "content_pack.json"
    art_path = src / "listening_articles.json"

    pack = load(pack_path)
    art_doc = load(art_path)

    chunk_bundle = build_chunks(pack)
    known = {c["id"] for c in chunk_bundle["chunks"]}
    article_bundle = build_articles(art_doc, known)

    chunk_bundle["source"] = {
        "pack": "content_pack.json",
        "sha256": sha256(pack_path),
    }
    article_bundle["source"] = {
        "pack": "listening_articles.json",
        "sha256": sha256(art_path),
    }

    dump(out / "chunks.json", chunk_bundle)
    dump(out / "articles.json", article_bundle)
    print(
        f"OK 块 {chunk_bundle['count']}（T0={chunk_bundle['tiers']['T0']} "
        f"T1={chunk_bundle['tiers']['T1']} T2={chunk_bundle['tiers']['T2']}）"
        f" / 文章 {article_bundle['count']}（句 {article_bundle['sentenceCount']}）"
    )


if __name__ == "__main__":
    main()
