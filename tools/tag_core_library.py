# -*- coding: utf-8 -*-
"""核心词块库标签器（指令 N §一/§二）。

输入：
  assets/content_pack.json       存量 20 关 / 487 块
  assets/listening_articles.json 16 篇浸泡文章（154 处标注 / 99 个唯一块）
  /d/tmp/google10k.txt           google-10000-english 词频表（第一版频率证据）

输出：
  assets/content_pack.json       v1.2.0：旧 type→semantic；新增 tier/funcCat/type/freqRank/sources；
                                 场景层新增 requires_chunks/combos（DDS §19.1）
  <evidence>/存量块标签表.md
  <evidence>/T0核心库清单.md
  <evidence>/tag_audit.json      逐块四标准分量，供复核

口径说明见 DDS §25。所有"可浮现性"打分都是规则启发式，不是心理学常模；
频率排名只来自 google-10000 词表，未用 COCA 等未取得的语料，绝不伪造。
"""
import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
PACK = ROOT / "assets/content_pack.json"
LISTEN = ROOT / "assets/listening_articles.json"
FREQ = pathlib.Path("D:/tmp/google10k.txt")
EVID = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else None

FUNC_CATS = ["寒暄开场", "应答回应", "观点立场", "请求协助", "确认澄清", "时间计划", "情绪评价", "委婉缓冲"]
TYPES = ["固定搭配", "短语动词", "句型框架", "惯用表达"]
TIERS = ["T0", "T1", "T2"]

# 旧语义色类别 → 保持不变，但 JSON 键改名为 semantic，给新 type 让位。
SEMANTIC_KEYS = {"content", "function", "timeplace", "greeting"}

STOP = set("""
a an the i you he she it we they me us him her them my your his its our their this that these those
am is are was were be been being do does did done have has had will would shall should can could may might must
to of in on at for with by from about as into over after before under between out up down off back
and or but so if because than then there here not no yes very too just please some any more most much many
one two three ten first second next last same another what which who whom whose when where why how
""".split())

PARTICLES = set("up down out in on off over back away through along around by".split())
VERBS = set("""
wake get brush take make have check feed walk pack catch go come pick drop turn look check clean do sit
pay book cook split save stay feel taste order eat leave try exchange give pass bring lend keep call follow
rebook board land arrive wait stand hold move hang put set run write read speak listen wear work start stop
open close fill sign send receive pay buy sell rent drive ride fly grow show meet join celebrate bring
""".split())

# 句型框架的触发模式（整块文本匹配；宁可少判，不硬套）。
FRAME_PATTERNS = [
    r"^i'?d like\b", r"^i'?m\b", r"^i am\b", r"^i want\b", r"^i need\b", r"^i think\b",
    r"^i prefer\b", r"^i don'?t\b", r"^i can'?t\b", r"^i was wondering\b", r"^i'?m looking for\b",
    r"^could (i|you)\b", r"^can (i|you)\b", r"^would (you|i)\b", r"^may i\b", r"^do you\b",
    r"^are you\b", r"^where (is|can|are)\b", r"^what (time|size|does|do)\b", r"^how (much|far|about)\b",
    r"^let'?s\b", r"^let me\b", r"^give me\b", r"^pass me\b", r"^bring me\b", r"^help me\b",
    r"^it'?s\b", r"^it is\b", r"^that'?s\b", r"^there (is|are)\b", r"^this is\b", r"^the .+ is\b",
]

IDIOMS = {
    "take care", "see you", "see you tomorrow", "see you soon", "see you there", "nice to meet you",
    "have a nice day", "call it a day", "no problem", "no worries", "never mind", "of course",
    "on the house", "it's on me", "keep the change", "make yourself at home", "take it easy",
    "cheer up", "good idea", "that works", "count me in", "be my guest", "after you", "go ahead",
    "hold on", "why not", "exactly right", "my pleasure", "you're welcome", "me too", "me neither",
    "i'm afraid not", "sort of", "no way", "what a pity", "small hours", "right away", "by all means",
    "not at all", "sure thing", "for sure", "to be honest", "in other words", "on the contrary",
    "at your convenience", "thank you in advance", "if you don't mind", "would you mind",
    "nice to meet you", "sounds good", "casual is fine", "the small hours", "bear with me",
}

CONCRETE = set("""
coffee tea milk sugar water ice shot muffin croissant sandwich burger pizza soup salad bread cake dessert
menu bill receipt tip table chair window door room key card towel bed shower toilet restroom kitchen floor
elevator balcony heater light bag box ticket pass passport gate seat flight plane airport station bus taxi
train subway map corner block crossroad exit entrance street park museum beach library school church market
hospital pharmacy bank hotel mall gym bar theater temple office meeting room desk computer phone laptop
umbrella coat boots hat shirt shoes size color brand price discount refund warranty napkin fork knife spoon
cup glass bottle plate bowl food breakfast lunch dinner snack fruit vegetable meat rice noodles egg
cat dog bag money coin dollar euro yuan card cash change budget deadline appointment calendar clock watch
doctor nurse medicine prescription insurance ambulance weather rain snow wind storm sun cloud umbrella
toothbrush soap shampoo brush hair face hand head eye ear mouth foot leg arm body
""".split())

ABSTRACT = set("""
think agree disagree opinion view suppose doubt important useless useful meaning sense idea reason
possibility probably maybe perhaps sure certain wrong right true false free busy free
""".split())

# 8 类默认归属：按场景主题给默认值，再逐块覆盖。
LEVEL_DEFAULT = {
    "A": "寒暄开场", "B": "请求协助", "C": "请求协助", "D": "请求协助", "E": "请求协助",
    "F": "请求协助", "G": "请求协助", "H": "请求协助", "I": "请求协助", "J": "时间计划",
    "K": "情绪评价", "L": "情绪评价", "M": "观点立场", "N": "请求协助", "O": "委婉缓冲",
    "P": "应答回应", "Q": "应答回应", "R": "确认澄清", "S": "时间计划", "T": "请求协助",
}

OVERRIDES = {
    # 寒暄/客套
    "thank you": "寒暄开场", "excuse me": "委婉缓冲", "enjoy your meal": "寒暄开场",
    "have a nice day": "寒暄开场", "good morning": "寒暄开场", "good evening": "寒暄开场",
    "see you": "寒暄开场", "see you tomorrow": "时间计划", "see you soon": "时间计划",
    "see you there": "时间计划", "nice to meet you": "寒暄开场", "take care": "寒暄开场",
    # 应答
    "you're welcome": "应答回应", "my pleasure": "应答回应", "no problem": "应答回应",
    "no worries": "应答回应", "never mind": "应答回应", "of course": "应答回应",
    "for sure": "应答回应", "sure thing": "应答回应", "that works": "应答回应",
    "got it": "应答回应", "i see": "应答回应", "i get it": "确认澄清", "me too": "应答回应",
    "me neither": "应答回应", "definitely yes": "应答回应", "definitely not": "应答回应",
    "keep the change": "应答回应", "it's on me": "应答回应", "good idea": "应答回应",
    "why not": "应答回应", "exactly right": "确认澄清", "no thanks": "应答回应",
    "yes please": "应答回应", "no thank you": "应答回应", "not at all": "应答回应",
    "be my guest": "应答回应", "after you": "应答回应", "go ahead": "应答回应",
    "hold on": "应答回应", "right away": "应答回应", "wait a moment": "应答回应",
    # 确认澄清
    "i don't understand": "确认澄清", "say that again": "确认澄清", "speak slowly": "确认澄清",
    "what does mean": "确认澄清", "please translate": "确认澄清", "speak louder": "确认澄清",
    "say clearly": "确认澄清", "what do you mean": "确认澄清", "could you repeat": "确认澄清",
    "in other words": "确认澄清", "please clarify": "确认澄清", "are you sure": "确认澄清",
    "that's right": "确认澄清", "that's wrong": "确认澄清", "not exactly": "确认澄清",
    "it's closed": "确认澄清", "cash only": "确认澄清", "in stock": "确认澄清",
    "sold out": "确认澄清", "make sense": "确认澄清", "i follow": "确认澄清",
    "missed that": "确认澄清", "what time": "时间计划", "how far": "确认澄清",
    # 委婉缓冲
    "maybe": "委婉缓冲", "perhaps another": "委婉缓冲", "i'm afraid not": "委婉缓冲",
    "sort of": "委婉缓冲", "could be": "委婉缓冲", "hardly any": "委婉缓冲",
    "i'm not sure": "委婉缓冲", "not really": "委婉缓冲", "i guess so": "委婉缓冲",
    "i suppose not": "委婉缓冲", "i'd say no": "委婉缓冲", "maybe next time": "委婉缓冲",
    "would you mind": "委婉缓冲", "if you don't mind": "委婉缓冲", "no rush": "委婉缓冲",
    "bear with me": "委婉缓冲", "i was wondering": "委婉缓冲", "it's not urgent": "委婉缓冲",
    "at your convenience": "委婉缓冲", "sorry to bother": "委婉缓冲", "i suppose": "委婉缓冲",
    "to be honest": "观点立场", "in my view": "观点立场", "i think": "观点立场",
    "i agree": "观点立场", "i disagree": "观点立场", "i doubt": "观点立场",
    "i prefer": "观点立场", "i like": "观点立场", "i don't like": "观点立场",
    "no way": "观点立场", "what a pity": "情绪评价", "on the contrary": "观点立场",
    # 情绪评价
    "tastes good": "情绪评价", "too salty": "情绪评价", "too sweet": "情绪评价",
    "very sour": "情绪评价", "so bitter": "情绪评价", "too expensive": "情绪评价",
    "too tight": "情绪评价", "too loose": "情绪评价", "too pricey": "情绪评价",
    "feel hungry": "情绪评价", "feel full": "情绪评价", "taste tasty": "情绪评价",
    "feel better": "情绪评价", "it's good": "情绪评价", "it's bad": "情绪评价",
    "the best": "情绪评价", "the worst": "情绪评价", "cheer up": "情绪评价",
    "take it easy": "情绪评价", "no worries": "应答回应",
    # 时间计划
    "call it a day": "时间计划", "a coffee break": "时间计划", "open late": "时间计划",
    "right now": "时间计划", "a bit later": "时间计划", "on time": "时间计划",
    "in a hurry": "时间计划", "make plans": "时间计划", "must cancel": "时间计划",
    "let's reschedule": "时间计划", "are you free": "时间计划", "i am busy": "时间计划",
    # 请求协助
    "follow up": "请求协助", "rebook my flight": "请求协助", "self checkout": "请求协助",
    "take it with food": "请求协助", "a badge": "确认澄清", "the agenda": "确认澄清",
    "the meeting room": "确认澄清", "action items": "时间计划", "a quick recap": "确认澄清",
    "side effects": "确认澄清", "the insurance card": "确认澄清", "the waiting room": "确认澄清",
    "a prescription": "请求协助", "security check": "请求协助", "boarding pass": "请求协助",
    "baggage claim": "请求协助", "connecting flight": "请求协助", "a gate change": "确认澄清",
    "a boarding group": "确认澄清", "gate number": "确认澄清", "a taxi stand": "请求协助",
    "an aisle seat": "请求协助", "window seat": "请求协助", "a vegetarian option": "请求协助",
    "still water": "请求协助", "extra napkins": "请求协助", "no ice": "请求协助",
    "oat milk": "请求协助", "an extra shot": "请求协助", "a slower pace": "委婉缓冲",
    "the small hours": "时间计划",
}

PLACEHOLDER_CN = {}


def norm(s):
    s = s.lower().replace("\u2019", "'").strip()
    s = re.sub(r"\s+", " ", s)
    s = re.sub(r"[.!?]+$", "", s)
    return s


def tokenize(s):
    return [t for t in re.findall(r"[a-z']+", norm(s)) if t]


def headword(text):
    toks = [t.rstrip("'") for t in tokenize(text)]
    content = [t for t in toks if t not in STOP]
    pool = content or toks
    ranked = [(FREQ_MAP.get(t, 0), t) for t in pool]
    ranked.sort(key=lambda x: (x[0] == 0, -x[0]))
    return ranked[0][1] if ranked else ""


def freq_rank(text):
    toks = [t.rstrip("'") for t in tokenize(text)]
    content = [t for t in toks if t not in STOP]
    pool = content or toks
    ranks = [FREQ_MAP.get(t, 0) for t in pool]
    ranks = [r for r in ranks if r > 0]
    return max(ranks) if ranks else 0


def guess_type(text, sem):
    n = norm(text)
    if n in IDIOMS:
        return "惯用表达"
    toks = tokenize(text)
    if len(toks) >= 2 and toks[0] in VERBS and toks[-1] in PARTICLES:
        return "短语动词"
    if any(re.search(p, n) for p in FRAME_PATTERNS):
        return "句型框架"
    return "固定搭配"


def score_block(text, sem, func, typ, rank, article_ids, level_ids, sent_count):
    """四标准分量：F 频率 20 / G 通用性 30 / I 可浮现 20 / P 产出 30，合计 100。

    权重取舍：核心库服务「能开口」，故语用通用性与产出价值各占 30；
    频率只作证据不主导，避免把高频但难产出的名词堆成 T0。
    """
    # 1) 频率证据（0–20）
    if rank <= 0:
        f = 0
    elif rank <= 500:
        f = 20
    elif rank <= 1000:
        f = 18
    elif rank <= 2000:
        f = 14
    elif rank <= 3500:
        f = 10
    elif rank <= 5000:
        f = 6
    elif rank <= 7500:
        f = 3
    else:
        f = 1
    # 2) 语用通用性（0–30）
    g = 0
    g += 12 if len(article_ids) >= 3 else 8 if len(article_ids) == 2 else 5 if len(article_ids) == 1 else 0
    g += 7 if len(level_ids) >= 3 else 4 if len(level_ids) == 2 else 0
    g += {"寒暄开场": 6, "应答回应": 6, "请求协助": 7, "确认澄清": 5, "时间计划": 5,
          "观点立场": 4, "情绪评价": 4, "委婉缓冲": 4}[func]
    g += 5 if sent_count >= 3 else 4 if sent_count == 2 else 3 if sent_count == 1 else 0
    g = min(g, 30)
    # 3) 可浮现性（0–20，规则启发式）
    toks = tokenize(text)
    i = {"content": 13, "timeplace": 15, "greeting": 12, "function": 8}.get(sem, 10)
    hits = sum(1 for t in toks if t in CONCRETE)
    i += 5 if hits >= 2 else 2 if hits == 1 else 0
    if any(t in ABSTRACT for t in toks):
        i -= 5
    n = len(toks)
    i += 2 if 2 <= n <= 4 else 0 if n == 1 else -2
    i = max(0, min(i, 20))
    # 4) 产出价值（0–30）
    p = {"句型框架": 16, "短语动词": 13, "固定搭配": 11, "惯用表达": 12}[typ]
    if re.search(r"\b(i|you|we|can|could|would|what|where|how|let)\b", norm(text)):
        p += 7
    p += 4 if len(article_ids) >= 2 else 2 if len(article_ids) == 1 else 0
    p += 4 if sent_count >= 2 else 2 if sent_count == 1 else 0
    p += 2 if 2 <= n <= 4 else 0
    if typ == "固定搭配" and sem == "content" and n <= 3 and len([t for t in toks if t not in STOP]) <= 1:
        p -= 4  # 裸名词短语：可背但产出面窄
    p = max(0, min(p, 30))
    return f, g, i, p


def level_requires_and_combos(pack):
    """DDS §19.1：requires_chunks = 前序关块在本关目标句中的真实复用；
    combos = 本关内同句共现 ≥2 的块。两者都从既有内容推导，不手工编造。"""
    id_to_level = {}
    for lv in pack["levels"]:
        for c in lv["chunks"]:
            id_to_level[c["id"]] = lv["id"]
    order = {lv["id"]: i for i, lv in enumerate(pack["levels"])}
    for lv in pack["levels"]:
        own = {c["id"] for c in lv["chunks"]}
        req, combos = set(), set()
        for s in lv.get("sentences", []):
            ids = [i for i in s.get("chunkIds", []) if i in id_to_level]
            if len(ids) >= 2:
                combos.update(ids)
            for i in ids:
                if order[id_to_level[i]] < order[lv["id"]]:
                    req.add(i)
        lv["requires_chunks"] = sorted(req)
        lv["combos"] = sorted(combos)


def main():
    global FREQ_MAP
    if not FREQ.exists():
        raise SystemExit(f"缺少频率表：{FREQ}")
    FREQ_MAP = {}
    for i, line in enumerate(FREQ.read_text(encoding="utf-8").splitlines(), 1):
        w = line.strip().lower()
        if w and w not in FREQ_MAP:
            FREQ_MAP[w] = i

    pack = json.loads(PACK.read_text(encoding="utf-8"))
    listen = json.loads(LISTEN.read_text(encoding="utf-8"))

    # 文章块：文本键 → 来源/释义/id
    art = {}
    for a in listen["articles"]:
        for s in a["sentences"]:
            for c in s.get("chunks", []):
                k = norm(c["text"])
                rec = art.setdefault(k, {"ids": set(), "text": c["text"], "cn": c.get("meaningCN", ""), "articles": set()})
                rec["ids"].add(c["id"])
                rec["articles"].add(a["id"])
                if not rec["cn"]:
                    rec["cn"] = c.get("meaningCN", "")

    # 旧 type → semantic；先统计文本→关卡集合
    text_levels = {}
    for lv in pack["levels"]:
        for c in lv["chunks"]:
            if "semantic" not in c:
                c["semantic"] = c.pop("type", "content")
            if c["semantic"] not in SEMANTIC_KEYS:
                raise SystemExit(f"未知 semantic：{c['id']} {c['semantic']}")
            text_levels.setdefault(norm(c["text"]), set()).add(lv["id"])

    # 仅见于文章、未进内容包的块 = Q-1 候选块（lx_*）。候选不是库内块：
    # 不并入 content_pack（会撞 candidate schema 且在文章里无宿主句），
    # 只在标签账本中单列，待宿主池后续成篇时再转正。
    candidates = []
    for k, rec in sorted(art.items()):
        if k in text_levels:
            continue
        candidates.append({
            "text": rec["text"],
            "meaningCN": rec["cn"],
            "ids": sorted(rec["ids"]),
            "articles": sorted(rec["articles"]),
        })

    # 目标句引用计数
    sent_count = {}
    for lv in pack["levels"]:
        for s in lv.get("sentences", []):
            for cid in s.get("chunkIds", []):
                sent_count[cid] = sent_count.get(cid, 0) + 1

    # 逐块打标（首次出现计算，文本相同的结果共享）
    per_text = {}
    for lv in pack["levels"]:
        for c in lv["chunks"]:
            k = norm(c["text"])
            if k not in per_text:
                func = OVERRIDES.get(k) or LEVEL_DEFAULT[lv["id"]]
                typ = guess_type(c["text"], c["semantic"])
                rank = freq_rank(c["text"])
                arts = sorted(art.get(k, {}).get("articles", []))
                levels = sorted(text_levels[k])
                reuse = sent_count.get(c["id"], 0)
                f, g, i, p = score_block(c["text"], c["semantic"], func, typ, rank, arts, levels, reuse)
                per_text[k] = dict(func=func, type=typ, rank=rank, f=f, g=g, i=i, p=p,
                                   total=f + g + i + p, arts=arts, levels=levels,
                                   head=headword(c["text"]), reuse=reuse)
            t = per_text[k]
            c["funcCat"] = t["func"]
            c["type"] = t["type"]
            c["freqRank"] = t["rank"]
            src = [f"pack:level/{lv['id']}"]
            if t["arts"]:
                src.append("article/" + ",".join(t["arts"]))
            src.append(f"freq/google-10000#{t['rank']}" if t["rank"] else "freq/google-10000#unlisted")
            if len(t["levels"]) > 1:
                src.append("merge/text")
            c["sources"] = src

    # T0 选取：按文本唯一，四标准总分排序，再补两条覆盖约束。
    unique = list(per_text.items())
    ranked = sorted(unique, key=lambda kv: (-kv[1]["total"], kv[1]["rank"] or 99999, kv[0]))
    chosen = [k for k, _ in ranked[:100]]

    def hosted(k):
        return bool(per_text[k]["arts"])

    # 覆盖约束：8 类都要有存在感，但不允许单一功能类吞掉半个 T0。
    CAPS = {"寒暄开场": 12, "应答回应": 14, "观点立场": 12, "请求协助": 26,
            "确认澄清": 12, "时间计划": 14, "情绪评价": 12, "委婉缓冲": 10}
    MINS = {c: 5 for c in FUNC_CATS}
    for _ in range(400):
        changed = False
        for cat in FUNC_CATS:
            have = [k for k in chosen if per_text[k]["func"] == cat]
            if len(have) > CAPS[cat]:
                drop = min(have, key=lambda x: (per_text[x]["total"], x))
                cand = next((k for k, t in ranked if k not in chosen and t["func"] != cat
                             and sum(1 for x in chosen if per_text[x]["func"] == t["func"]) < CAPS[t["func"]]), None)
                if cand:
                    chosen.remove(drop)
                    chosen.append(cand)
                    changed = True
            elif len(have) < MINS[cat]:
                cand = next((k for k, t in ranked if k not in chosen and t["func"] == cat), None)
                if cand:
                    drop = min((x for x in chosen
                                if len([y for y in chosen if per_text[y]["func"] == per_text[x]["func"]]) > MINS[per_text[x]["func"]]),
                               key=lambda x: (per_text[x]["total"], x), default=None)
                    if drop:
                        chosen.remove(drop)
                        chosen.append(cand)
                        changed = True
        if not changed:
            break
    chosen = sorted(chosen, key=lambda k: (-per_text[k]["total"], per_text[k]["rank"] or 99999, k))
    chosen_set = set(chosen)

    # T1：剩余分数 ≥55 或前 150；其余 T2
    rest = [(k, t) for k, t in ranked if k not in chosen_set]
    t1 = {k for k, t in rest[:150] if t["total"] >= 55}
    for lv in pack["levels"]:
        for c in lv["chunks"]:
            k = norm(c["text"])
            c["tier"] = "T0" if k in chosen_set else ("T1" if k in t1 else "T2")

    pack["version"] = "1.2.0"
    level_requires_and_combos(pack)
    PACK.write_text(json.dumps(pack, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

    # 审计与证据
    if EVID:
        EVID.mkdir(parents=True, exist_ok=True)
        audit = {
            "generatedAt": "2026-10-25",
            "freqSource": "google-10000-english-no-swears (first20hours), 9,894 lines, fetched 2026-10-25",
            "note": "可浮现性为规则启发式（具体名词表 + 抽象词惩罚 + 长度），非心理学常模；频率排名取块内最低频实词。",
            "blocks": {},
            "candidates": candidates,
            "candidateCount": len(candidates),
        }
        for k, t in per_text.items():
            audit["blocks"][k] = dict(t)
        (EVID / "tag_audit.json").write_text(json.dumps(audit, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

        # 存量块标签表
        lines = ["# 存量块标签表（指令 N §一）", "",
                 "生成：2026-10-25 · 来源 `tools/tag_core_library.py` · 逐块分量见 `tag_audit.json`", "",
                 "| 关 | 块 id | 块面 | 释义 | tier | 功能类 | 类型 | 频率排名 | 宿主篇目 | 来源 |",
                 "|---|---|---|---|---|---|---|---|---|---|"]
        for lv in pack["levels"]:
            for c in lv["chunks"]:
                t = per_text[norm(c["text"])]
                host = ",".join(t["arts"]) or "—"
                lines.append(f"| {lv['id']} | {c['id']} | {c['text']} | {c['meaningCN']} | {c['tier']} | "
                             f"{c['funcCat']} | {c['type']} | {c['freqRank'] or '—'} | {host} | {'; '.join(c['sources'])} |")

        lines += ["", f"## 文章候选块（仅见于 16 篇、未入内容包，{len(candidates)} 块）", "",
                  "候选块保持 `lx_*` id 与 `candidate: true`，不进 `content_pack.json`；",
                  "文本与库内块按归一化文本合并（重复即命中库内块，不再单列）。", "",
                  "| 块面 | 释义 | 候选 id | 来源文章 | 功能类 | 类型 | 频率排名 | tier |",
                  "|---|---|---|---|---|---|---|---|"]
        for rec in candidates:
            k = norm(rec["text"])
            func = OVERRIDES.get(k, "请求协助")
            typ = guess_type(rec["text"], "content")
            rank = freq_rank(rec["text"])
            lines.append(f"| {rec['text']} | {rec['meaningCN']} | {','.join(rec['ids'])} | "
                         f"{','.join(rec['articles'])} | {func} | {typ} | {rank or '—'} | 候选（未入包） |")
        (EVID / "存量块标签表.md").write_text("\n".join(lines) + "\n", encoding="utf-8")

        # T0 清单
        t0 = [k for k in chosen]
        lines = ["# T0 核心库清单（首批 100，指令 N §二）", "",
                 "生成：2026-10-25 · 选块标准见 DDS §25 · 逐块分量见 `tag_audit.json`", "",
                 "四标准分量：频率证据 F/20 · 语用通用性 G/30 · 可浮现性 I/20 · 产出价值 P/30，合计 100。",
                 "频率排名取块内最低频实词在 google-10000 中的位次；0 = 未入表。", "",
                 "| # | 块面 | 释义 | 功能类 | 类型 | 频率排名 | F | G | I | P | 总分 | 宿主篇目 | 文献来源 |",
                 "|---:|---|---|---|---|---:|---:|---:|---:|---:|---:|---|---|"]
        for idx, k in enumerate(t0, 1):
            t = per_text[k]
            # 释义：优先内容包，再文章
            cn = ""
            for lv in pack["levels"]:
                for c in lv["chunks"]:
                    if norm(c["text"]) == k:
                        cn = c["meaningCN"]
                        break
                if cn:
                    break
            if not cn:
                cn = art.get(k, {}).get("cn", "")
            host = ",".join(t["arts"]) or "—（待宿主）"
            refs = f"google-10000#{t['rank']}" if t["rank"] else "google-10000（未入表）"
            if t["arts"]:
                refs += "；article/" + ",".join(t["arts"])
            lines.append(f"| {idx} | {k} | {cn} | {t['func']} | {t['type']} | {t['rank'] or '—'} | "
                         f"{t['f']} | {t['g']} | {t['i']} | {t['p']} | **{t['total']}** | {host} | {refs} |")
        pool = [k for k in chosen if not hosted(k)]
        lines += ["", f"## 待宿主池（T0 中尚无文章承载，{len(pool)} 块）", "",
                  "第二批 8 篇（L17–L24）已从本池消化 54 个块面；以下块未获宿主，",
                  "留待后续波次成篇时转正（候选块仍不入库）。", "",
                  "、".join(pool)]
        (EVID / "T0核心库清单.md").write_text("\n".join(lines) + "\n", encoding="utf-8")

    print(f"pack v{pack['version']} levels={len(pack['levels'])} chunks={sum(len(l['chunks']) for l in pack['levels'])} "
          f"unique={len(per_text)} candidates={len(candidates)} T0={len(chosen)} unhosted={sum(1 for k in chosen if not hosted(k))}")
    dist = {}
    for k in chosen:
        dist[per_text[k]["func"]] = dist.get(per_text[k]["func"], 0) + 1
    print("T0 funcCats", dist)
    print("type dist", {t: sum(1 for k in chosen if per_text[k]['type'] == t) for t in TYPES})


if __name__ == "__main__":
    main()
