# -*- coding: utf-8 -*-
"""内容包校验器（DDS §19.2 + 指令 N §一.1）。

规则：
  1. 关卡字段齐全，场景层 requires_chunks / combos 为 id 数组且引用真实存在的块；
     combos 限本关，requires_chunks 限前序关。
  2. 每块五字段齐全且合法：tier ∈ T0/T1/T2；funcCat ∈ 八类；type ∈ 四类；
     freqRank 为非负整数；sources 为非空字符串数组。
  3. id 全局唯一；目标句引用的块必须存在。
  4. 浸泡文章的库内块必须能在包内找到且文本一致；Q-1 候选块（candidate: true /
     lx_ 前缀）不入内容包，只在文章内存在，但必须满足 lx_ 前缀且与库内 id 不撞。

用法：
  python tools/validate_content_pack.py [assets/content_pack.json] [assets/listening_articles.json]
退出码 1 表示存在错误（进包闸门据此阻断构建）。
"""
import json
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
DEFAULT_PACK = ROOT / "assets/content_pack.json"
DEFAULT_LISTEN = ROOT / "assets/listening_articles.json"

TIERS = {"T0", "T1", "T2"}
FUNC_CATS = {"寒暄开场", "应答回应", "观点立场", "请求协助", "确认澄清", "时间计划", "情绪评价", "委婉缓冲"}
TYPES = {"固定搭配", "短语动词", "句型框架", "惯用表达"}
SEMANTICS = {"content", "function", "timeplace", "greeting"}


def norm(s):
    return " ".join(str(s).lower().split()).strip(" .!?")


def validate(pack_path, listen_path=None):
    errors = []
    try:
        pack = json.loads(pathlib.Path(pack_path).read_text(encoding="utf-8"))
    except Exception as e:  # noqa: BLE001 - 校验器要把解析错误也变成逐条报告
        return [f"无法读取内容包：{e}"]

    levels = pack.get("levels")
    if not isinstance(levels, list) or not levels:
        return ["levels 缺失或为空"]

    ids = {}
    level_order = {}
    for li, lv in enumerate(levels):
        lid = lv.get("id")
        if not lid:
            errors.append(f"levels[{li}] 缺少 id")
            continue
        level_order[lid] = li
        for key in ("theme", "sceneImage", "chunks", "requires_chunks", "combos"):
            if key not in lv:
                errors.append(f"关 {lid} 缺少字段 {key}")
        for key in ("requires_chunks", "combos"):
            v = lv.get(key)
            if not isinstance(v, list) or any(not isinstance(x, str) for x in v):
                errors.append(f"关 {lid} 的 {key} 必须是 id 字符串数组")
        for ci, c in enumerate(lv.get("chunks", [])):
            where = f"关 {lid} chunks[{ci}]"
            cid = c.get("id")
            if not cid:
                errors.append(f"{where} 缺少 id")
                continue
            if cid in ids:
                errors.append(f"块 id 重复：{cid}（{ids[cid]} / {lid}）")
            ids[cid] = lid
            for key in ("text", "semantic", "meaningCN", "tier", "funcCat", "type", "freqRank", "sources"):
                if key not in c:
                    errors.append(f"{cid} 缺少字段 {key}")
            if c.get("semantic") not in SEMANTICS:
                errors.append(f"{cid} semantic 非法：{c.get('semantic')}")
            if c.get("tier") not in TIERS:
                errors.append(f"{cid} tier 非法：{c.get('tier')}")
            if c.get("funcCat") not in FUNC_CATS:
                errors.append(f"{cid} funcCat 非法：{c.get('funcCat')}")
            if c.get("type") not in TYPES:
                errors.append(f"{cid} type 非法：{c.get('type')}")
            fr = c.get("freqRank")
            if not isinstance(fr, int) or isinstance(fr, bool) or fr < 0:
                errors.append(f"{cid} freqRank 必须是非负整数：{fr!r}")
            src = c.get("sources")
            if not isinstance(src, list) or not src or any(not isinstance(x, str) or not x.strip() for x in src):
                errors.append(f"{cid} sources 必须是非空字符串数组")

    # 引用检查（块建完后做）
    for lv in levels:
        lid = lv.get("id")
        own = {c.get("id") for c in lv.get("chunks", [])}
        for key in ("requires_chunks", "combos"):
            for ref in lv.get(key, []) or []:
                if ref not in ids:
                    errors.append(f"关 {lid} 的 {key} 引用不存在的块 {ref}")
                elif key == "combos" and ref not in own:
                    errors.append(f"关 {lid} 的 combos 只能引用本关块，越界 {ref}")
                elif key == "requires_chunks" and level_order.get(ids[ref], 0) >= level_order.get(lid, 0):
                    errors.append(f"关 {lid} 的 requires_chunks 只能引用前序关，越界 {ref}")
        for s in lv.get("sentences", []) or []:
            for ref in s.get("chunkIds", []) or []:
                if ref not in ids:
                    errors.append(f"关 {lid} 目标句 {s.get('id')} 引用不存在的块 {ref}")

    if listen_path:
        try:
            listen = json.loads(pathlib.Path(listen_path).read_text(encoding="utf-8"))
        except Exception as e:  # noqa: BLE001
            errors.append(f"无法读取浸泡文章：{e}")
            listen = {"articles": []}
        by_id = {}
        for lv in levels:
            for c in lv.get("chunks", []):
                by_id[c.get("id")] = norm(c.get("text", ""))
        for a in listen.get("articles", []):
            for s in a.get("sentences", []):
                for c in s.get("chunks", []):
                    cid = c.get("id") or ""
                    is_cand = bool(c.get("candidate")) or cid.startswith("lx_")
                    if is_cand:
                        if not cid.startswith("lx_"):
                            errors.append(f"文章 {a.get('id')} 候选块 id 须以 lx_ 开头：{cid}")
                        if cid in by_id:
                            errors.append(f"文章 {a.get('id')} 候选块 id 与库内块冲突：{cid}")
                        if not c.get("text", "").strip():
                            errors.append(f"文章 {a.get('id')} 候选块文本为空：{cid}")
                        continue
                    if cid not in by_id:
                        errors.append(f"文章 {a.get('id')} 引用包外块 {cid}（{c.get('text')}）")
                    elif by_id[cid] != norm(c.get("text", "")):
                        errors.append(f"文章 {a.get('id')} 块 {cid} 文本与包内不一致：{c.get('text')} vs {by_id[cid]}")
    return errors


def main():
    pack = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT_PACK
    listen = pathlib.Path(sys.argv[2]) if len(sys.argv) > 2 else (DEFAULT_LISTEN if DEFAULT_LISTEN.exists() else None)
    errors = validate(pack, listen)
    if errors:
        print(f"内容包校验失败：{len(errors)} 个错误")
        for e in errors:
            print(" -", e)
        return 1
    print(f"内容包校验通过：{pack}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
