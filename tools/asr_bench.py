# -*- coding: utf-8 -*-
"""ASR 基准测量 CLI（1.5.8.2 · #248④ / MASTER-160 §二-1）

用途：批量把 WAV 跑一遍 Vosk，用**与 App 完全同源的判定口径**算四个数：
    WER（严格词错率）/ 虚词命中率（弱读判效指标）/ 实词命中率 / judgeSpeech 通过率，
外加解码耗时与 RTF。发布门对拍就认这四列，不认手感。

口径单一真源（关键设计）：
    - 不在本文件重写任何判定逻辑。评分函数**直接执行 `tools/vosk_sim.py` 的源码前缀**
      （`# ---------- 识别` 之前的部分），因此 `normalize_speech` / `word_close` /
      `is_function` / `weighted_align` / `judge_speech` 与发版门禁脚本**逐字一致**；
    - 该前缀又声明与 `lib/services/speech_judge.dart` 保持一致（改判定须两处同改）。
    - `tools/test_asr_bench.py` 会额外把 Python 虚词表 / 混淆对与 Dart 源码逐项比对，
      防两边漂移。

用法：
    python tools/asr_bench.py --manifest bench/manifest.json --model D:\\tmp\\vosk-model\\vosk-model-small-en-us-0.15
    python tools/asr_bench.py --manifest bench/manifest.json --score-only   # 只算分（条目自带 hyp）
    python tools/asr_bench.py --manifest bench/manifest.json --out bench/out.json

Manifest（见 tools/README-asr-bench.md）：
    {"kind": "pipeline-smoke | self-recorded | baseline",
     "items": [{"id":"N-01","ref":"I would like a cup of coffee.","wav":"a.wav",
                "tags":["normal"],"speaker":"Zira"}]}

红线：
    - `kind != "baseline"` 时结果一律带 `"baseline": false` 并打印「非基线」横幅；
      **非基线数字不得写进 DDS §20.5.1，也不得作为发布门证据**。
    - 样本音频只留本机，不进仓；本脚本只输出数字与文本。
"""

import argparse
import io
import json
import os
import sys
import time
import wave

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_MODEL = r"D:\tmp\vosk-model\vosk-model-small-en-us-0.15"

# ── 复用发版门禁脚本的判定函数（零重写） ─────────────────────────────────────
def _load_judge_namespace():
    src_path = os.path.join(HERE, "vosk_sim.py")
    src = io.open(src_path, encoding="utf-8").read()
    marker = "# ---------- 识别"
    if marker not in src:
        raise SystemExit("vosk_sim.py 结构变了：找不到 '%s' 分界，先修好再跑基准。" % marker)
    prefix = src.split(marker)[0]

    class _StubModel:  # 只挡住模块级的 Model() 构造，不碰任何判定函数
        def __init__(self, *a, **k):
            pass

    ns = {"__name__": "vosk_sim_judge_prefix", "__file__": src_path}
    ns["Model"] = _StubModel
    exec(compile(prefix, src_path, "exec"), ns)
    return ns


_J = _load_judge_namespace()
_normalize = _J["normalize_speech"]
_tokens = _J["tokenize"]
_word_close = _J["word_close"]
_is_function = _J["is_function"]
_weighted_align = _J["weighted_align"]
_judge = _J["judge_speech"]


# ── 指标 ────────────────────────────────────────────────────────────────────
def _levenshtein_words(a, b):
    m, n = len(a), len(b)
    dp = list(range(n + 1))
    for i in range(1, m + 1):
        prev, dp[0] = dp[0], i
        for j in range(1, n + 1):
            cur = dp[j]
            dp[j] = min(dp[j] + 1, dp[j - 1] + 1, prev + (0 if a[i - 1] == b[j - 1] else 1))
            prev = cur
    return dp[n]


def wer(ref, hyp):
    """严格词错率：编辑距离 / 参考词数（参考为空时返回 0.0）。"""
    r, h = _tokens(ref), _tokens(hyp)
    if not r:
        return 0.0
    return _levenshtein_words(r, h) / len(r)


def close_wer(ref, hyp):
    """容错词错率：同编辑距离，但按 `word_close` 计同词（与判定口径一致，仅作旁证）。"""
    r, h = _tokens(ref), _tokens(hyp)
    if not r:
        return 0.0
    m, n = len(h), len(r)
    dp = list(range(n + 1))
    for i in range(1, m + 1):
        prev, dp[0] = dp[0], i
        for j in range(1, n + 1):
            cur = dp[j]
            cost = 0 if _word_close(h[i - 1], r[j - 1]) else 1
            dp[j] = min(dp[j] + 1, dp[j - 1] + 1, prev + cost)
            prev = cur
    return dp[n] / n


def _recalls(ref, hyp):
    """虚词/实词命中率：用发版门禁同款 weighted_align 的逐词命中标记。"""
    r, h = _tokens(ref), _tokens(hyp)
    if not r:
        return (1.0, 1.0, 0, 0)
    _wsim, _core, matched = _weighted_align(h, r)
    fw_total = sum(1 for w in r if _is_function(w))
    fw_hit = sum(1 for k, w in enumerate(r) if _is_function(w) and matched[k])
    cw_total = len(r) - fw_total
    cw_hit = sum(1 for k, w in enumerate(r) if not _is_function(w) and matched[k])
    fw = 1.0 if fw_total == 0 else fw_hit / fw_total
    cw = 1.0 if cw_total == 0 else cw_hit / cw_total
    return (fw, cw, fw_total, cw_total)


def score_item(item, hyp, latency=None, duration=None):
    ref = item["ref"]
    w = wer(ref, hyp)
    cw_wer = close_wer(ref, hyp)
    fw, cw, fw_n, cw_n = _recalls(ref, hyp)
    out = _judge(ref, hyp, None, duration)
    row = {
        "id": item.get("id", ""),
        "tags": item.get("tags", []),
        "speaker": item.get("speaker", ""),
        "ref": ref,
        "hyp": hyp,
        "wer": round(w, 4),
        "closeWer": round(cw_wer, 4),
        "funcRecall": round(fw, 4),
        "contentRecall": round(cw, 4),
        "funcWords": fw_n,
        "contentWords": cw_n,
        "judgePass": bool(out.get("passed")),
        "judgeReason": out.get("reason", ""),
    }
    if latency is not None:
        row["decodeSec"] = round(latency, 3)
    if duration:
        row["audioSec"] = round(duration, 3)
        row["rtf"] = round((latency or 0) / duration, 4)
    return row


def aggregate(rows, key=None):
    sel = rows if key is None else [r for r in rows if key in r["tags"]]
    if not sel:
        return None
    n = len(sel)
    fw_den = sum(r["funcWords"] for r in sel)
    cw_den = sum(r["contentWords"] for r in sel)
    return {
        "n": n,
        "wer": round(sum(r["wer"] for r in sel) / n, 4),
        "closeWer": round(sum(r["closeWer"] for r in sel) / n, 4),
        # 命中率按词数加权，避免短句主导
        "funcRecall": round(
            sum(r["funcRecall"] * r["funcWords"] for r in sel) / fw_den, 4) if fw_den else None,
        "contentRecall": round(
            sum(r["contentRecall"] * r["contentWords"] for r in sel) / cw_den, 4) if cw_den else None,
        "judgePassRate": round(sum(1 for r in sel if r["judgePass"]) / n, 4),
        "avgDecodeSec": round(sum(r.get("decodeSec", 0) for r in sel) / n, 3),
        "avgRtf": round(sum(r.get("rtf", 0) for r in sel) / n, 4),
    }


# ── 解码 ────────────────────────────────────────────────────────────────────
def _load_vosk_model(model_dir):
    if not os.path.isdir(model_dir):
        print("[模型缺失] 找不到 %s" % model_dir, file=sys.stderr)
        print("  先跑 tools/fetch_vosk_model.py 或把已解压模型指到 --model。", file=sys.stderr)
        sys.exit(3)
    import vosk
    vosk.SetLogLevel(-1)
    return vosk, vosk.Model(model_dir)


def decode(vosk, model, wav_path, grammar=None):
    wf = wave.open(wav_path, "rb")
    try:
        rate = wf.getframerate()
        dur = wf.getnframes() / float(rate)
        rec = vosk.KaldiRecognizer(model, rate, json.dumps(grammar)) if grammar \
            else vosk.KaldiRecognizer(model, rate)
        t0 = time.time()
        data = wf.readframes(4000)
        while data:
            rec.AcceptWaveform(data)
            data = wf.readframes(4000)
        text = json.loads(rec.FinalResult()).get("text", "")
        return text, dur, time.time() - t0
    finally:
        wf.close()


# ── 主流程 ──────────────────────────────────────────────────────────────────
def main(argv=None):
    # 输出确定化为 UTF-8：Windows 控制台/管道默认 cp936，重定向时中文会炸解码。
    for stream in (sys.stdout, sys.stderr):
        if hasattr(stream, "reconfigure"):
            try:
                stream.reconfigure(encoding="utf-8", errors="replace")
            except Exception:
                pass
    ap = argparse.ArgumentParser(description="ASR 基准测量（WAV→Vosk→App 同源判定口径）")
    ap.add_argument("--manifest", required=True, help="manifest.json（见 README）")
    ap.add_argument("--model", default=DEFAULT_MODEL, help="已解压 Vosk 模型目录")
    ap.add_argument("--out", help="结果 JSON 路径（默认打印到 stdout）")
    ap.add_argument("--score-only", action="store_true", help="不解码，用条目自带的 hyp 算分")
    ap.add_argument("--grammar", choices=["none", "target"], default="none",
                    help="none=全模型（基线与 WER 用这个）；target=带目标短语词表（诊断用）")
    ap.add_argument("--quiet", action="store_true")
    args = ap.parse_args(argv)

    try:
        man = json.load(io.open(args.manifest, encoding="utf-8"))
    except (OSError, ValueError) as e:
        print("[manifest 读不了] %s: %r" % (args.manifest, e), file=sys.stderr)
        return 2
    items = man.get("items") or []
    if not items:
        print("[空 manifest] %s 里没有 items" % args.manifest, file=sys.stderr)
        return 2
    kind = man.get("kind", "unknown")
    is_baseline = kind == "baseline"

    if not is_baseline:
        print("=" * 66)
        print("[非基线] kind=%s —— 这批数字只能验证管道，不得写入 DDS §20.5.1，" % kind)
        print("         也不得当作 1.5.8.2 发布门证据。真实基线须等 #253 B 段回收样本。")
        print("=" * 66)

    vosk = model = None
    if not args.score_only:
        need_decode = [it for it in items if "hyp" not in it]
        if need_decode:
            vosk, model = _load_vosk_model(args.model)

    rows = []
    for it in items:
        wav = it.get("wav")
        if "hyp" in it:  # 已带识别文本 → 只算分
            rows.append(score_item(it, it["hyp"], latency=it.get("decodeSec"),
                                   duration=it.get("audioSec")))
            continue
        if not wav:
            print("[跳过] %s 既无 hyp 也无 wav" % it.get("id"), file=sys.stderr)
            continue
        path = wav if os.path.isabs(wav) else os.path.join(os.path.dirname(args.manifest), wav)
        grammar = _J["vosk_grammar_words"]([it["ref"]]) if args.grammar == "target" else None
        try:
            hyp, dur, lat = decode(vosk, model, path, grammar)
        except Exception as e:  # 单条失败不拖垮整批
            print("[解码失败] %s: %r" % (it.get("id"), e), file=sys.stderr)
            continue
        rows.append(score_item(it, hyp, latency=lat, duration=dur))
        if not args.quiet:
            print("  %-8s wer=%.3f fw=%.3f pass=%s" % (
                it.get("id", ""), rows[-1]["wer"], rows[-1]["funcRecall"],
                "Y" if rows[-1]["judgePass"] else "N"))

    tags = sorted({t for r in rows for t in r["tags"]})
    report = {
        "kind": kind,
        "baseline": is_baseline,
        "manifest": os.path.abspath(args.manifest),
        "model": None if args.score_only else os.path.abspath(args.model),
        "grammar": args.grammar,
        "overall": aggregate(rows),
        "byTag": {t: aggregate(rows, t) for t in tags},
        "items": rows,
        "note": ("非基线：仅验证管道" if not is_baseline else "基线：可入 §20.5.1"),
    }

    text = json.dumps(report, ensure_ascii=False, indent=2)
    if args.out:
        os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
        io.open(args.out, "w", encoding="utf-8").write(text + "\n")
        print("[写出] %s" % args.out)

    o = report["overall"]
    print("\n== 汇总（%s） ==" % ("基线" if is_baseline else "非基线"))
    print("  n=%d  WER=%.4f  closeWER=%.4f  虚词命中=%.4f  实词命中=%.4f  判定通过=%.1f%%" % (
        o["n"], o["wer"], o["closeWer"],
        o["funcRecall"] if o["funcRecall"] is not None else float("nan"),
        o["contentRecall"] if o["contentRecall"] is not None else float("nan"),
        o["judgePassRate"] * 100))
    for t in tags:
        a = report["byTag"][t]
        print("  [%s] n=%d WER=%.4f 虚词=%.4f 通过=%.1f%%" % (
            t, a["n"], a["wer"],
            a["funcRecall"] if a["funcRecall"] is not None else float("nan"),
            a["judgePassRate"] * 100))
    if not args.out:
        print("\n" + text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
