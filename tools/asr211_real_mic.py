# -*- coding: utf-8 -*-
"""ASR-211 真人麦克风评测集执行器（20 句）

指令 ASR-211 §一.5：**今后识别引擎的裁定以真人麦克风数据为准**，不再用 TTS 合成音频代替。
本脚本就是那把尺子——真机念的 20 句发回来，一条命令出结果。

口径钉死（与 App 生产路径一致，别测假路径）：
  · 识别默认走**全模型**（不传语法）。B5 裁定就是「小语法只服务 E2E，生产不用」；
    想比对带语法的上限，再显式加 --grammar target。
  · 判定调 `tools/vosk_sim.py` 的判定前缀（与 Dart `judgeSpeech` 同一套规则，
    由 test/judge_parity_test.dart 逐条对拍钉住）。
  · 时长 <0.4s 由判卷层的 tooShort 分支处理，这里不另设门槛。

用法：
    python tools/asr211_real_mic.py --wavs D:/tmp/asr211            # 用默认评测集
    python tools/asr211_real_mic.py --wavs D:/tmp/asr211 --grammar target
    python tools/asr211_real_mic.py --wavs D:/tmp/asr211 --out D:/tmp/asr211/report

文件名认这几种：`<序号>_<句子id>.wav`、`<句子id>.wav`、`<句子id>_<任意后缀>.wav`
（兼容 gen_wavs.ps1 产出的 `<句子id>_<声音>_r<速率>.wav`）。

退出码：0 = 20 句齐；2 = 有缺（报告照出，但不许当成完整评测）；3 = 一句都没找到；
4 = 评测集与内容包对不上（句子改过文，先更新评测集）。
"""

import argparse
import array
import io
import json
import os
import re
import sys
import wave

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
if HERE not in sys.path:
    sys.path.insert(0, HERE)

import asr_bench  # noqa: E402  只 exec 判定前缀，不加载模型

_J = asr_bench._J
judge = _J["judge_speech"]
word_close = _J["word_close"]

SET_DEFAULT = os.path.join(ROOT, "release", "ASR-211", "评测集-20句.json")
PACK = os.path.join(ROOT, "assets", "content_pack.json")
MODEL_DIR = os.environ.get(
    "VOSK_MODEL_DIR", r"D:\tmp\vosk-model\vosk-model-small-en-us-0.15")
TARGET_RATE = 16000
_SID_RE = re.compile(r"([a-z]{1,3}_s\d+)")


def read_wav_mono16k(path):
    """读 WAV → 单声道 16k 16bit PCM；返回 (字节, 秒)。线性插值重采样，不引依赖。"""
    wf = wave.open(path, "rb")
    rate, ch, width = wf.getframerate(), wf.getnchannels(), wf.getsampwidth()
    raw = wf.readframes(wf.getnframes())
    wf.close()
    if width != 2:
        raise ValueError("%s：只支持 16bit PCM，实测 %d 字节/样本" % (path, width))
    samples = array.array("h")
    samples.frombytes(raw[:len(raw) - (len(raw) % 2)])
    if ch > 1:
        samples = samples[::ch]
    if rate != TARGET_RATE and len(samples):
        n = int(len(samples) * TARGET_RATE / float(rate))
        out = array.array("h")
        for k in range(n):
            pos = k * rate / float(TARGET_RATE)
            i0 = int(pos)
            i1 = min(i0 + 1, len(samples) - 1)
            frac = pos - i0
            out.append(int(samples[i0] * (1 - frac) + samples[i1] * frac))
        samples = out
    return samples.tobytes(), len(samples) / float(TARGET_RATE)


class Recorder:
    """一个模型实例跑多条录音（vosk.Model 构造慢，复用）。"""

    def __init__(self, model_dir):
        import vosk
        self._vosk = vosk
        self.model = vosk.Model(model_dir)

    def text(self, pcm, grammar=None):
        if grammar:
            rec = self._vosk.KaldiRecognizer(
                self.model, TARGET_RATE,
                json.dumps(grammar, ensure_ascii=False))
        else:
            rec = self._vosk.KaldiRecognizer(self.model, TARGET_RATE)
        rec.SetWords(False)
        step = 4000
        for i in range(0, len(pcm), step):
            rec.AcceptWaveform(pcm[i:i + step])
        return json.loads(rec.FinalResult()).get("text", "")


def find_wavs(dirpath):
    """→ {句子id: 文件名}；同一句多条时留字典序第一条。"""
    out = {}
    if not os.path.isdir(dirpath):
        return out
    for f in sorted(os.listdir(dirpath)):
        if not f.lower().endswith(".wav"):
            continue
        m = _SID_RE.search(f[:-4])
        if m and m.group(1) not in out:
            out[m.group(1)] = f
    return out


def pack_sentence(sid, target):
    """评测集里的句子必须还在内容包里，且文一致（改过文就要重新对靶）。"""
    j = json.load(io.open(PACK, encoding="utf-8"))
    for lv in j["levels"]:
        for s in lv.get("sentences", []):
            if s["id"] == sid:
                return s["text"].strip().lower() == target.strip().lower()
    return False


def main(argv=None):
    for stream in (sys.stdout, sys.stderr):
        if hasattr(stream, "reconfigure"):
            try:
                stream.reconfigure(encoding="utf-8", errors="replace")
            except Exception:
                pass

    ap = argparse.ArgumentParser(description="ASR-211 真人麦克风 20 句评测")
    ap.add_argument("--set", default=SET_DEFAULT, help="评测集 JSON")
    ap.add_argument("--wavs", required=True, help="真机录音目录")
    ap.add_argument("--out", help="报告输出目录（默认 <wavs>/report）")
    ap.add_argument("--model", default=MODEL_DIR)
    ap.add_argument("--grammar", choices=["open", "target"], default="open",
                    help="open=与 App 生产同口径（全模型）；target=带语法上限比对")
    a = ap.parse_args(argv)

    aset = json.load(io.open(a.set, encoding="utf-8"))
    items = aset["items"]
    bad = [it["sid"] for it in items if not pack_sentence(it["sid"], it["target"])]
    if bad:
        print("[评测集过期] 这些句子在内容包里已改文或不存在：%s —— 先更新 评测集-20句.json"
              % ", ".join(bad), file=sys.stderr)
        return 4

    found = find_wavs(a.wavs)
    if not found:
        print("[无录音] %s 里没匹配到任何一句（命名见脚本头部）" % a.wavs, file=sys.stderr)
        return 3
    missing = [it["sid"] for it in items if it["sid"] not in found]
    print("[取数] %d/%d 句到齐；缺 %s" % (len(items) - len(missing), len(items),
                                  ", ".join(missing) or "无"))

    rec = Recorder(a.model)
    rows = []
    for it in items:
        sid = it["sid"]
        if sid not in found:
            rows.append({"idx": it["idx"], "sid": sid, "target": it["target"],
                         "feature": it["feature"], "missing": True})
            continue
        path = os.path.join(a.wavs, found[sid])
        pcm, dur = read_wav_mono16k(path)
        grammar = _J["vosk_grammar_words"]([it["target"]]) if a.grammar == "target" else None
        text = rec.text(pcm, grammar)
        out = judge(it["target"], text, duration=dur)
        rows.append({
            "idx": it["idx"], "sid": sid, "file": found[sid],
            "target": it["target"], "feature": it["feature"],
            "watch": it.get("watch", ""), "hyp": text, "durSec": round(dur, 2),
            "passed": bool(out["passed"]), "reason": out["reason"],
            "band": out.get("band") or ("hit" if out["passed"] else "fail"),
            "coreHit": round(float(out.get("core") or 0.0), 3),
            "sim": round(float(out["sim"]), 3),
            "layer": out.get("layer", ""),
            "hint": out.get("deviationHint") or "",
            "wer": round(asr_bench.wer(it["target"], text), 3),
            "closeWer": round(asr_bench.close_wer(it["target"], text), 3),
        })

    done = [r for r in rows if not r.get("missing")]
    n = len(done)
    p = sum(1 for r in done if r["passed"])
    band = sum(1 for r in done if not r["passed"] and r["band"] == "band")
    fail = n - p - band
    empty = sum(1 for r in done if not r["hyp"].strip())
    avg_wer = sum(r["wer"] for r in done) / n if n else 0.0
    avg_cwer = sum(r["closeWer"] for r in done) / n if n else 0.0

    # 真人语音里最常整词丢掉的实词——这才是「换引擎值不值」的靶心。
    losses = {}
    for r in done:
        hyp = r["hyp"].lower().split()
        for t in _J["tokenize"](r["target"]):
            if not _J["is_function"](t) and not any(word_close(t, h) for h in hyp):
                losses[t] = losses.get(t, 0) + 1
    top_losses = sorted(losses.items(), key=lambda kv: (-kv[1], kv[0]))[:12]

    summary = {
        "kind": "asr211-real-mic-report",
        "set": os.path.relpath(a.set, ROOT).replace("\\", "/"),
        "engine": "vosk-model-small-en-us-0.15",
        "grammar": a.grammar,
        "model": a.model,
        "expected": len(items),
        "recorded": n,
        "missing": missing,
        "pass": p, "band": band, "fail": fail, "empty": empty,
        "passRate": round(p / n, 3) if n else 0.0,
        "passOrBandRate": round((p + band) / n, 3) if n else 0.0,
        "avgWer": round(avg_wer, 4),
        "avgCloseWer": round(avg_cwer, 4),
        "topMissingContentWords": [{"word": w, "count": c} for w, c in top_losses],
        "rows": rows,
        "caveat": "判定与 App 同源（vosk_sim 判定前缀，Dart 侧 judge_parity 逐条对拍）。"
                  "本报告是**引擎裁定依据**；TTS 合成集只能当回归看，不能拿来判换不换引擎。",
    }

    outdir = a.out or os.path.join(a.wavs, "report")
    os.makedirs(outdir, exist_ok=True)
    jp = os.path.join(outdir, "asr211-real-mic.json")
    io.open(jp, "w", encoding="utf-8", newline="\n").write(
        json.dumps(summary, ensure_ascii=False, indent=2) + "\n")

    md = ["# ASR-211 真人麦克风评测（%d/%d 句到齐）" % (n, len(items)), ""]
    md.append("- 引擎：Vosk small-en-us-0.15 ｜ 识别口径：%s ｜ 判定与 App 同源"
              % ("全模型（生产同口径）" if a.grammar == "open" else "带语法（上限）"))
    md.append("- 判对 %d · 差一点 %d · 判错 %d · 空转写 %d ｜ 通过率 %.0f%%（含差一点 %.0f%%）"
              % (p, band, fail, empty, 100 * summary["passRate"],
                 100 * summary["passOrBandRate"]))
    md.append("- WER 均值 %.1f%% ｜ 容错 WER 均值 %.1f%%" % (100 * avg_wer, 100 * avg_cwer))
    if missing:
        md.append("- **缺录音**：%s —— 本份不是完整评测，别据此下结论" % ", ".join(missing))
    md += ["", "| # | 句子 | 覆盖点 | 实际转写 | 结果 | 核心命中 | WER |",
           "|---|------|--------|----------|------|----------|-----|"]
    for r in rows:
        if r.get("missing"):
            md.append("| %d | %s | %s | （未收到录音） | — | — | — |"
                      % (r["idx"], r["sid"], r["feature"]))
            continue
        res = "判对" if r["passed"] else ("差一点" if r["band"] == "band" else "判错")
        md.append("| %d | %s | %s | `%s` | %s | %.2f | %.0f%% |"
                  % (r["idx"], r["sid"], r["feature"], r["hyp"] or "(空)", res,
                     r["coreHit"], 100 * r["wer"]))
    md += ["", "## 真人语音里最常整词丢掉的实词", ""]
    md.append(" ｜ ".join("`%s`×%d" % (w, c) for w, c in top_losses)
              if top_losses else "（本轮没有整词丢失的实词）")
    mdp = os.path.join(outdir, "asr211-real-mic.md")
    io.open(mdp, "w", encoding="utf-8", newline="\n").write("\n".join(md) + "\n")

    print("  判对 %d · 差一点 %d · 判错 %d ｜ 通过率 %.0f%% ｜ WER %.1f%%"
          % (p, band, fail, 100 * summary["passRate"], 100 * avg_wer))
    print("  [写出] %s" % mdp)
    print("  [写出] %s" % jp)
    return 0 if not missing else 2


if __name__ == "__main__":
    sys.exit(main())
