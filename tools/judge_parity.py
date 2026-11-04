# -*- coding: utf-8 -*-
"""Dart / Python 判定对拍夹具生成器（1.5.9 · §30.2 对拍）

背景：App 的判定（`lib/services/speech_judge.dart`）与发布门禁/基准集的 Python 镜像
（`tools/vosk_sim.py`）是两份实现。`test_asr_bench.py` 只守「虚词表/混淆对」不漂移，
**不守行为**。本脚本用一张固定的合成用例表，把 Python 侧结论写成夹具，
再由 `test/judge_parity_test.dart` 逐条断言 Dart 侧给出**同一结论**。

为什么夹具来自 Python 而不是 Dart：Python 那份是发布门/基准集的执行体，
Dart 是用户实际跑的判定；两者必须同判。夹具进仓（纯文本、无音频、无用户数据），
每次改判定两边都要重新跑这条对拍。

用法：
    python tools/judge_parity.py            # 写 test/fixtures/judge_parity.json
    python tools/judge_parity.py --check    # 只比对，不写（CI 用）
"""

import argparse
import io
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

import asr_bench  # noqa: E402  复用「执行 vosk_sim 判定前缀」的加载器，零重写

_J = asr_bench._J
_judge = _J["judge_speech"]
_tokens = _J["tokenize"]

FIXTURE = os.path.join(HERE, "..", "test", "fixtures", "judge_parity.json")

# 目标句：来自 App 内容包的口语短句（A1–B1），不是造出来的绕口令。
TARGETS = [
    "good morning everyone",
    "i would like a cup of coffee",
    "how much does it cost",
    "could you say that again please",
    "i am looking for the train station",
    "she went to the park with her friends",
    "can i have the bill please",
    "i will be there in ten minutes",
    "what time does the meeting start",
    "thank you so much for your help",
    "let me know if you need anything",
    "we should leave before it gets dark",
]


def _drop_function(t):
    """删掉第一个虚词（最常见的弱读丢失）。无虚词时返回 None（不造重复用例）。"""
    words = t.split()
    for i, w in enumerate(words):
        if _J["is_function"](w):
            return " ".join(words[:i] + words[i + 1:])
    return None


def _drop_content(t):
    """删掉第一个实词（说错/吞词）。"""
    words = t.split()
    for i, w in enumerate(words):
        if not _J["is_function"](w):
            return " ".join(words[:i] + words[i + 1:])
    return None


def _split_word(t):
    """整词被拆（morning → morn ing）：取最长的实词从中间断开。"""
    words = t.split()
    cands = [(len(w), i) for i, w in enumerate(words)
             if not _J["is_function"](w) and len(w) >= 6]
    if not cands:
        return None
    _, i = max(cands)
    w = words[i]
    mid = len(w) // 2
    return " ".join(words[:i] + [w[:mid], w[mid:]] + words[i + 1:])


def _swap_last(t):
    """末两词颠倒。"""
    words = t.split()
    if len(words) < 3:
        return None
    words[-1], words[-2] = words[-2], words[-1]
    return " ".join(words)


def _typo(t):
    """实词错一个字母（编辑距离 1，判近似）。"""
    words = t.split()
    for i, w in enumerate(words):
        if not _J["is_function"](w) and len(w) > 3:
            words[i] = w[:-1] + ("t" if w[-1] != "t" else "s")
            return " ".join(words)
    return None


def _extra_tail(t):
    """尾巴多词（噪声）。"""
    return t + " you know"


def build_cases():
    """造用例。**拒绝退化用例**：hyp 规范化后与目标相同、或与已有用例四元组重复的，一律不收。

    上一版的教训：`_drop_function` 在没有虚词的目标（"good morning everyone"）上返回原文，
    夹具里就混进了一批「漏虚词=完全一致」的假用例，reason 全落 exact，
    还让「置信度低 → 拒判」那条实际走了完全匹配通道——标注与结论对不上。
    """
    cases = []
    seen = set()
    skipped = []

    def add(target, hyp, conf=None, dur=None, note=""):
        key = (target, hyp, conf, dur)
        if key in seen:
            raise ValueError("重复用例：%s / %s（%s）" % (target, hyp, note))
        seen.add(key)
        cases.append({"target": target, "hyp": hyp, "confidence": conf,
                      "durationSec": dur, "note": note})

    def try_add(target, hyp, note):
        """变异可能无效（该句无虚词/无长词），无效就跳过并记账，不写假用例。"""
        if hyp is None or _tokens(hyp) == _tokens(target):
            skipped.append(note)
            return
        add(target, hyp, note=note)

    for t in TARGETS:
        add(t, t, note="完全一致")
        add(t, t.upper() + "!", note="大小写与标点不影响")
        try_add(t, _drop_function(t), "漏一个虚词")
        try_add(t, _drop_content(t), "漏一个实词")
        try_add(t, _split_word(t), "整词被拆")
        try_add(t, _swap_last(t), "末两词颠倒")
        try_add(t, _typo(t), "实词错一个字母")
        try_add(t, _extra_tail(t), "尾巴多词（噪声）")

    # 置信度与时长分支：必须用**含虚词**的句子，否则「近似文本」造不出来，
    # 拒判/放行两条分支都测不到（会退化成完全匹配通道）。
    t = TARGETS[1]  # i would like a cup of coffee
    near = _drop_function(t)
    assert near and _tokens(near) != _tokens(t), "特殊分支的目标句必须能造出近似文本"
    add(t, t, conf=0.9, note="置信度高")
    add(t, t, conf=0.2, note="置信度低但文本一致 → 完全匹配通道不看置信度")
    add(t, near, conf=0.2, note="文本近似 + 置信度低 → 拒判")
    add(t, near, conf=0.6, note="文本近似 + 置信度达标 → 通过")
    # 「文本近似 + 置信度缺失」在循环里已有（漏一个虚词的 conf=None）→ 不重复造。
    add(t, "", note="空转写")
    add(t, t, dur=0.2, note="录音过短")
    add(t, t, dur=3.0, note="时长正常")
    add(t, "completely unrelated sentence here", note="跨句无关语音")

    # 已知差（不是 bug，是两侧口径不同）：Dart 在加权层之外还有一条**未加权**
    # 底线 kMinSimilarity=0.5（防「噪声里凑出目标词」混过），Python 基准只算加权。
    # 噪声**插进**目标词之间（不是整段尾巴）：包含通道不命中，加权 0.833 → 放行；
    # Dart 未加权 0.375 → lowSim 拒判。钉在这里，哪天两边口径统一了，这条会立刻红。
    # （注意：整段尾巴追加的口头语走包含通道，两侧都放行，不再属于已知差。）
    cases.append({
        "target": "good morning everyone",
        "hyp": "so good and morning the everyone if and",
        "confidence": None,
        "durationSec": None,
        "note": "噪声插进目标词之间：Dart 走未加权 0.5 底线拒判，Python 只看加权放行 → 已知差",
        "divergence": "noiseFloor",
    })

    return cases, skipped


_BRANCHES = ("exact", "fuzzy", "lowCore", "lowSim", "lowConf", "empty", "tooShort")


def main(argv=None):
    for stream in (sys.stdout, sys.stderr):
        if hasattr(stream, "reconfigure"):
            try:
                stream.reconfigure(encoding="utf-8", errors="replace")
            except Exception:
                pass

    ap = argparse.ArgumentParser(description="判定对拍夹具生成（Dart ⇄ Python）")
    ap.add_argument("--check", action="store_true", help="只比对现有夹具，不写")
    args = ap.parse_args(argv)

    cases, skipped = build_cases()
    for c in cases:
        out = _judge(c["target"], c["hyp"], c["confidence"], c["durationSec"])
        c["expect"] = {
            "passed": bool(out["passed"]),
            "reason": out["reason"],
            "similarity": round(float(out["sim"]), 4),
        }

    # 分支覆盖闸：七个分支必须全部出现过，少一条说明用例退化了，对拍等于没测。
    by_reason = {}
    for c in cases:
        r = c["expect"]["reason"]
        by_reason[r] = by_reason.get(r, 0) + 1
    missing = [b for b in _BRANCHES if b not in by_reason]
    if missing:
        print("[覆盖不足] 缺分支：%s —— 对拍用例退化了，先修 build_cases()" % ", ".join(missing),
              file=sys.stderr)
        return 6

    payload = {
        "kind": "judge-parity",
        "note": ("由 tools/judge_parity.py 生成：Python 侧 tools/vosk_sim.py 判定前缀的结论。"
                 "Dart 侧 test/judge_parity_test.dart 必须逐条同判；"
                 "带 divergence 字段的是**已知差**，Dart 侧按该字段断言差异方向。"),
        "cases": cases,
    }
    text = json.dumps(payload, ensure_ascii=False, indent=2) + "\n"
    path = os.path.abspath(FIXTURE)

    if args.check:
        if not os.path.isfile(path):
            print("[缺夹具] %s" % path, file=sys.stderr)
            return 4
        with io.open(path, encoding="utf-8") as f:
            old = f.read()
        if old != text:
            print("[夹具过期] 判定变了或用例变了：重跑 python tools/judge_parity.py", file=sys.stderr)
            return 5
        print("[一致] 夹具与 Python 侧结论相同（%d 条）" % len(cases))
        return 0

    os.makedirs(os.path.dirname(path), exist_ok=True)
    io.open(path, "w", encoding="utf-8", newline="\n").write(text)
    print("[写出] %s（%d 条）" % (path, len(cases)))
    print("  reason 分布：%s" % ", ".join("%s=%d" % kv for kv in sorted(by_reason.items())))
    if skipped:
        print("  变异跳过 %d 条（该句无虚词/无长词，不写假用例）：%s"
              % (len(skipped), ", ".join(sorted(set(skipped)))))
    return 0


if __name__ == "__main__":
    sys.exit(main())
