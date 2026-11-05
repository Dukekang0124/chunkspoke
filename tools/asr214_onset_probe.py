#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""ASR-214 取证：真机「USE WAS GREAT」吞词复现（禁止猜数）。

对同一条目标句，用**生产同款模型**跑五条通道，并做句首截断扫描：
  A vosk 自由解码（= 默认路径 transcribeOpen）
  B vosk grammar = 词块词表（= 生产二过在「自由造句」里实际拿到的词表：只有 main course）
  C vosk grammar = 参考句词表（拟议修复：把母语者参考句也喂进去）
  D zipformer 20M 无热词
  E zipformer 20M 热词=词块（= 生产「增强识别」主路径实际形状）
  F zipformer 20M 热词=词块+参考句（拟议修复）

句首截断 0/100/…/800ms 模拟「按下前已开口/预卷不够」。判定用生产同一套
judge（tools/vosk_sim.judge_speech），target=词块 "main course"。
"""
import json
import os
import subprocess
import sys
import wave

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)

from vosk import Model, KaldiRecognizer, SetLogLevel  # noqa: E402

# vosk_sim.py 是「函数 + 尾部评测脚本」混排；直接 import 会跑完整 487 句评测并炸在空集上。
# 这里只 exec 到 `results = []` 之前，取生产判定函数本体（判定逻辑一字不改）。
_src = open(os.path.join(HERE, 'vosk_sim.py'), encoding='utf-8').read()
_cut = _src.index('\nresults = []')
_sim_ns = {'__file__': os.path.join(HERE, 'vosk_sim.py')}
exec(compile(_src[:_cut], 'vosk_sim.py(judging only)', 'exec'), _sim_ns)  # noqa: S102
judge_speech = _sim_ns['judge_speech']


VOSK_MODEL = r"D:/tmp/vosk-model/vosk-model-small-en-us-0.15"
ZIP_MODEL = r"D:/tmp/spike/models/sherpa-onnx-streaming-zipformer-en-20M-2023-02-17"
WAV = r"D:/tmp/asr214/wav/S_mc_MicrosoftZiraDesktop_r0.wav"

TARGET_CHUNK = "main course"
REF_SENTENCE = "The main course was great."
CLIPS = [0, 100, 200, 300, 400, 500, 600, 700, 800]


def read_pcm16(path):
    with wave.open(path, 'rb') as w:
        assert w.getnchannels() == 1 and w.getsampwidth() == 2, w.getparams()
        return w.readframes(w.getnframes()), w.getframerate()


def write_clip(path, pcm, rate, clip_ms):
    n = int(rate * clip_ms / 1000) * 2
    out = path.replace('.wav', f'_c{clip_ms}.wav')
    with wave.open(out, 'wb') as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(rate)
        w.writeframes(pcm[n:])
    return out


def grammar_words(text):
    toks = [t for t in "".join(c if c.isalnum() or c == "'" else ' '
                               for c in text.lower()).split() if t]
    return sorted(set(toks))


def vosk_run(model, wav_path, words=None):
    rec = (KaldiRecognizer(model, 16000, json.dumps(words, ensure_ascii=False))
           if words else KaldiRecognizer(model, 16000))
    with wave.open(wav_path, 'rb') as w:
        data = w.readframes(w.getnframes())
    step = 4096
    for i in range(0, len(data), step):
        rec.AcceptWaveform(data[i:i + step])
    return json.loads(rec.FinalResult()).get('text', '').strip()


_ZIP = None


def zip_recognizer():
    """与 App 内 OnlineRecognizer 同配置：int8 三件 + modified_beam_search + maxActivePaths 4。"""
    global _ZIP
    if _ZIP is None:
        import sherpa_onnx
        pick = lambda p: os.path.join(ZIP_MODEL, p)
        _ZIP = (sherpa_onnx.OnlineRecognizer.from_transducer(
            tokens=pick('tokens.txt'),
            encoder=pick('encoder-epoch-99-avg-1.int8.onnx'),
            decoder=pick('decoder-epoch-99-avg-1.int8.onnx'),
            joiner=pick('joiner-epoch-99-avg-1.int8.onnx'),
            num_threads=2,
            decoding_method='modified_beam_search',
            max_active_paths=4,
            enable_endpoint_detection=False,
            hotwords_score=1.5,
        ), sherpa_onnx)
    return _ZIP


def zip_run(wav_path, hotwords):
    rec, _ = zip_recognizer()
    stream = rec.create_stream(hotwords) if hotwords else rec.create_stream()
    with wave.open(wav_path, 'rb') as w:
        sr = w.getframerate()
        pcm = w.readframes(w.getnframes())
    import array
    samples = array.array('h', pcm)
    floats = [s / 32768.0 for s in samples]
    chunk = 1600
    for i in range(0, len(floats), chunk):
        stream.accept_waveform(sr, floats[i:i + chunk])
    stream.input_finished()
    while rec.is_ready(stream):
        rec.decode_stream(stream)
    return rec.get_result(stream).strip()



def judge(text):
    """生产判定镜像：target=词块，duration 固定 1.0s（避开 tooShort 干扰，只看文本层）。"""
    return judge_speech(TARGET_CHUNK, text or '', duration=1.0)



def main():
    SetLogLevel(-1)
    print('[load] vosk model ...', flush=True)
    vm = Model(VOSK_MODEL)
    pcm, rate = read_pcm16(WAV)
    rows = []
    for clip in CLIPS:
        path = write_clip(WAV, pcm, rate, clip)
        a = vosk_run(vm, path)
        b = vosk_run(vm, path, grammar_words(TARGET_CHUNK))
        c = vosk_run(vm, path, grammar_words(REF_SENTENCE))
        try:
            d = zip_run(path, '')
            e = zip_run(path, 'MAIN COURSE')
            f = zip_run(path, 'MAIN COURSE THE WAS GREAT')
        except Exception as ex:  # sherpa CLI 不可用则标未证实，不编数
            d = e = f = f'<未跑成: {type(ex).__name__} {str(ex)[:120]}>'
        rows.append(dict(clip_ms=clip, a=a, b=b, c=c, d=d, e=e, f=f))
        print(f'clip={clip:>3}ms  A={a!r}  B={b!r}  C={c!r}  D={d!r}  E={e!r}  F={f!r}',
              flush=True)
    print('\n=== 判定（target=词块 main course）===')
    for r in rows:
        for k, name in [('a', 'A vosk自由'), ('b', 'B vosk语法块'), ('c', 'C vosk语法句'),
                        ('d', 'D zip无热词'), ('e', 'E zip热词块'), ('f', 'F zip热词句')]:
            t = r[k]
            if t.startswith('<'):
                print(f"clip={r['clip_ms']:>3} {name}: {t}")
                continue
            o = judge(t)
            print(f"clip={r['clip_ms']:>3} {name}: {t!r} → passed={o.get('passed')} "
                  f"sim={o.get('sim')} reason={o.get('reason')} band={o.get('band')}")
    out = os.path.join(HERE, 'asr214_probe.json')
    json.dump(rows, open(out, 'w', encoding='utf-8'), ensure_ascii=False, indent=1)
    print('\n[out]', out)


if __name__ == '__main__':
    main()
