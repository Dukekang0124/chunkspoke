#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""ASR-209 B 层：候选识别引擎 WER / RTF / 体积实测（禁止猜数）。

目的：回答一个问题——把线上 vosk small-0.15 换成 sherpa-onnx zipformer 20M
（或 whisper-tiny.en）后，**目标句集的词错率**是否真的降一半以上。

口径（与发布门一致，避免自欺）：
  - 同一批 WAV（内容包 517 句，Zira 标准美音，16 kHz 单声道，正常语速）；
  - 两个引擎都**不带**语法/热词提示，原始音频进、文本出；
  - WER = 严格词错率（规范化后编辑距离 / 参考词数）；汇总按词数加权，
    不是逐句平均（短句不能主导结论）；
  - RTF = 解码墙钟 / 音频时长（本机 CPU；低端机需真机复测，见报告）。

用法：
  python tools/asr209_b_bench.py \
      --wav-dir D:/tmp/asr209b/wav \
      --vosk-model D:/tmp/vosk-model/vosk-model-small-en-us-0.15 \
      --sherpa-model D:/tmp/spike/models/sherpa-onnx-streaming-zipformer-en-20M-2023-02-17 \
      --out release/ASR-209/B-识别层实测.json

输出里所有模型体积/sha256 都是本次现场计算的，不接受手填。
"""
import argparse
import collections
import hashlib
import io
import json
import os
import sys
import time
import wave

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)

import asr_bench  # noqa: E402  复用同一套规范化 / WER


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b''):
            h.update(chunk)
    return h.hexdigest()


def dir_fingerprint(path, suffixes=None):
    """递归统计：vosk 模型分在 am/ graph/ ivector/ 子目录里，只扫顶层会漏掉 70 MB。"""
    files = []
    for root, _dirs, names in os.walk(path):
        for name in sorted(names):
            if suffixes and not name.endswith(tuple(suffixes)):
                continue
            p = os.path.join(root, name)
            rel = os.path.relpath(p, path).replace(os.sep, '/')
            files.append({'name': rel, 'bytes': os.path.getsize(p),
                          'sha256': sha256_file(p)})
    return {'path': os.path.abspath(path), 'files': files,
            'totalBytes': sum(f['bytes'] for f in files)}


def read_wav(path, pad_lead=0.0, pad_tail=0.0):
    import numpy as np
    with wave.open(path, 'rb') as wf:
        assert wf.getframerate() == 16000, path
        assert wf.getnchannels() == 1, path
        assert wf.getsampwidth() == 2, path
        n = wf.getnframes()
        data = wf.readframes(n)
    samples = np.frombuffer(data, dtype=np.int16).astype('float32') / 32768.0
    orig_dur = n / 16000.0
    # 前卷/后卷：sherpa 流式 zipformer 需要若干 chunk 预热，否则句首被吃掉
    # （实测：不补时 "I would like a cup of coffee" 只出 "OF COFFEE"；补 2 s
    # 后整句正确）。为公平，两个引擎喂**同一份**加了静音的音频。
    if pad_lead or pad_tail:
        pre = np.zeros(int(16000 * pad_lead), dtype='float32') if pad_lead else None
        post = np.zeros(int(16000 * pad_tail), dtype='float32') if pad_tail else None
        parts = [p for p in (pre, samples, post) if p is not None]
        samples = np.concatenate(parts)
    return samples, orig_dur, len(samples) / 16000.0


class VoskDecoder:
    name = 'vosk-small-en-us-0.15'

    def __init__(self, model_dir):
        import vosk
        vosk.SetLogLevel(-1)
        self.model = vosk.Model(model_dir)
        self.vosk = vosk

    def decode(self, samples, dur, target=None):
        rec = self.vosk.KaldiRecognizer(self.model, 16000)
        t0 = time.time()
        data = (samples * 32767).astype('int16').tobytes()
        step = 8000  # 0.5 s
        for i in range(0, len(data), step):
            rec.AcceptWaveform(data[i:i + step])
        text = json.loads(rec.FinalResult()).get('text', '')
        return text, time.time() - t0


class SherpaZipformerDecoder:
    """sherpa-onnx 流式 zipformer 20M int8。

    [hotwords=True] 时把**目标句**作为上下文偏置注入（App 判卷场景本来就知道目标句，
    这是 §四「热词注入」的真实形态）；同时改用 modified_beam_search —— 热词偏置
    只在 beam search 下生效，greedy 会忽略它。
    """

    def __init__(self, model_dir, hotwords=False):
        import sherpa_onnx
        self.sherpa = sherpa_onnx
        self.use_hotwords = hotwords
        self.name = 'sherpa-zipformer-en-20M-int8' + ('+hotwords' if hotwords else '')
        self.rec = sherpa_onnx.OnlineRecognizer.from_transducer(
            tokens=os.path.join(model_dir, 'tokens.txt'),
            encoder=os.path.join(model_dir, 'encoder-epoch-99-avg-1.int8.onnx'),
            decoder=os.path.join(model_dir, 'decoder-epoch-99-avg-1.int8.onnx'),
            joiner=os.path.join(model_dir, 'joiner-epoch-99-avg-1.int8.onnx'),
            num_threads=2,
            sample_rate=16000,
            feature_dim=80,
            decoding_method='modified_beam_search' if hotwords else 'greedy_search',
            max_active_paths=8 if hotwords else 4,
            hotwords_score=1.5,
            enable_endpoint_detection=False,
        )

    def decode(self, samples, dur, target=None):
        t0 = time.time()
        hw = None
        if self.use_hotwords and target:
            # 热词表只认 tokens.txt 里的字母 token：大写 + 去标点（带标点会整条被跳过）。
            hw = ' '.join(w for w in target.upper().replace("'", ' ').split() if w.isalpha())
        stream = self.rec.create_stream(hw) if hw else self.rec.create_stream()
        stream.accept_waveform(16000, samples)
        stream.input_finished()
        while self.rec.is_ready(stream):
            self.rec.decode_stream(stream)
        text = self.rec.get_result(stream)
        return (text.strip() if isinstance(text, str) else ''), time.time() - t0


class SherpaWhisperDecoder:
    name = 'sherpa-whisper-tiny.en'

    def __init__(self, model_dir):
        import glob
        import sherpa_onnx

        def pick(kind):
            # 优先 int8（体积口径与移动端一致），没有再退回 fp32。
            for pat in ('*%s*int8.onnx' % kind, '*%s*.onnx' % kind):
                hits = sorted(glob.glob(os.path.join(model_dir, pat)))
                if hits:
                    return hits[0]
            raise SystemExit('whisper 目录里找不到 %s 文件：%s' % (kind, model_dir))

        tokens = sorted(glob.glob(os.path.join(model_dir, '*tokens*')))[0]
        self.rec = sherpa_onnx.OfflineRecognizer.from_whisper(
            encoder=pick('encoder'),
            decoder=pick('decoder'),
            tokens=tokens,
            language='en',
            task='transcribe',
            num_threads=2,
        )

    def decode(self, samples, dur, target=None):
        t0 = time.time()
        stream = self.rec.create_stream()
        stream.accept_waveform(16000, samples)
        self.rec.decode_stream(stream)
        text = stream.result.text
        return (text.strip() if isinstance(text, str) else ''), time.time() - t0


def word_edits(ref, hyp):
    r, h = asr_bench._tokens(ref), asr_bench._tokens(hyp)
    if not r:
        return 0, 0
    return asr_bench._levenshtein_words(r, h), len(r)


def run(decoder, items, pad_lead=0.0, pad_tail=0.0, quiet=False):
    rows = []
    fed_total = 0.0
    for k, (sid, ref, wav) in enumerate(items):
        samples, dur, fed = read_wav(wav, pad_lead, pad_tail)
        fed_total += fed
        try:
            hyp, sec = decoder.decode(samples, dur, target=ref)
        except Exception as e:  # 单条失败不拖垮整批
            print('  DECODE FAIL', sid, repr(e), file=sys.stderr)
            hyp, sec = '', 0.0
        edits, words = word_edits(ref, hyp)
        rows.append({'id': sid, 'ref': ref, 'hyp': hyp,
                     'edits': edits, 'words': words,
                     'wer': (edits / words) if words else 0.0,
                     'decodeSec': round(sec, 4),
                     'audioSec': round(dur, 3),
                     'rtf': round(sec / fed, 4) if fed else 0.0})
        if not quiet and (k + 1) % 50 == 0:
            print('  %s %d/%d' % (decoder.name, k + 1, len(items)))
    total_e = sum(r['edits'] for r in rows)
    total_w = sum(r['words'] for r in rows)
    total_d = sum(r['decodeSec'] for r in rows)
    total_a = sum(r['audioSec'] for r in rows)
    return {
        'engine': decoder.name,
        'n': len(rows),
        'wer': round(total_e / total_w, 4) if total_w else 0.0,
        'wordEdits': total_e,
        'refWords': total_w,
        'empty': sum(1 for r in rows if not r['hyp'].strip()),
        'exactHitRate': round(sum(1 for r in rows if r['edits'] == 0) / len(rows), 4) if rows else 0.0,
        'avgDecodeSec': round(total_d / len(rows), 4) if rows else 0.0,
        'avgRtf': round(total_d / fed_total, 4) if fed_total else 0.0,
        'audioSecTotal': round(total_a, 1),
        'rows': rows,
    }


def main(argv=None):
    for stream in (sys.stdout, sys.stderr):
        if hasattr(stream, 'reconfigure'):
            try:
                stream.reconfigure(encoding='utf-8', errors='replace')
            except Exception:
                pass
    ap = argparse.ArgumentParser()
    ap.add_argument('--wav-dir', required=True)
    ap.add_argument('--pack', default=os.path.join(ROOT, 'assets', 'content_pack.json'))
    ap.add_argument('--vosk-model', required=True)
    ap.add_argument('--sherpa-model', required=True)
    ap.add_argument('--whisper-model', default=None)
    ap.add_argument('--limit', type=int, default=0, help='只跑前 N 条（调试用）')
    ap.add_argument('--only', default='',
                    help='逗号分隔的引擎白名单：vosk/zipformer/zipformer-hw/whisper（留空=全跑）')
    ap.add_argument('--pad-lead', type=float, default=2.0, help='前卷静音秒数（喂给两个引擎）')
    ap.add_argument('--pad-tail', type=float, default=0.5, help='后卷静音秒数')
    ap.add_argument('--out', default=os.path.join(ROOT, 'release', 'ASR-209', 'B-识别层实测.json'))
    args = ap.parse_args(argv)

    pack = json.load(io.open(args.pack, encoding='utf-8'))
    refs = {}
    for level in pack['levels']:
        for s in level.get('sentences') or []:
            refs['%s_%s' % (level['id'], s['id'])] = s['text']

    items = []
    for name in sorted(os.listdir(args.wav_dir)):
        if not name.endswith('.wav'):
            continue
        stem = name[:-4]
        # {level}_{sid}_{voice}_r{rate}
        parts = stem.rsplit('_', 2)
        if len(parts) != 3:
            continue
        sid = parts[0]
        if sid not in refs:
            continue
        items.append((sid, refs[sid], os.path.join(args.wav_dir, name)))
    if args.limit:
        items = items[:args.limit]
    if not items:
        raise SystemExit('没有可用的 WAV（检查 --wav-dir 与内容包 id 是否对齐）')

    print('样本：%d 句（Zira 正常语速，16 kHz 单声道，前卷 %.1fs / 后卷 %.1fs）'
          % (len(items), args.pad_lead, args.pad_tail))
    results = {
        'sample': {'n': len(items), 'voice': 'Microsoft Zira Desktop', 'rate': 0,
                   'wavDir': os.path.abspath(args.wav_dir),
                   'padLeadSec': args.pad_lead, 'padTailSec': args.pad_tail},
        'models': {
            'vosk': dir_fingerprint(args.vosk_model),
            'zipformer': dir_fingerprint(args.sherpa_model),
        },
        'runs': [],
    }

    only = {s.strip() for s in args.only.split(',') if s.strip()}

    def want(k):
        return not only or k in only

    vosk = zipf = ziph = None
    if want('vosk'):
        vosk = run(VoskDecoder(args.vosk_model), items, args.pad_lead, args.pad_tail)
        results['runs'].append(vosk)
    if want('zipformer'):
        zipf = run(SherpaZipformerDecoder(args.sherpa_model), items,
                   args.pad_lead, args.pad_tail)
        results['runs'].append(zipf)
    if want('zipformer-hw'):
        ziph = run(SherpaZipformerDecoder(args.sherpa_model, hotwords=True), items,
                   args.pad_lead, args.pad_tail)
        results['runs'].append(ziph)
    candidates = [r for r in (zipf, ziph) if r is not None]

    if want('whisper'):
        results['models']['whisper'] = dir_fingerprint(args.whisper_model) if args.whisper_model else None
        w = run(SherpaWhisperDecoder(args.whisper_model), items, args.pad_lead, args.pad_tail)
        results['runs'].append(w)
        candidates.append(w)
    candidates = [c for c in candidates if c is not None]

    if vosk is None:
        vosk = {'engine': '(skipped)', 'wer': float(os.environ.get('BASE_WER', '0') or 0),
                'exactHitRate': 0.0, 'empty': 0, 'avgRtf': 0.0, 'rows': []}
        results['runs'].insert(0, vosk)

    base = vosk['wer']
    print('\n== 汇总（按词数加权，基准 = %s） ==' % vosk['engine'])
    print('%-32s WER=%.4f  整句全对=%.1f%%  空=%d  RTF=%.4f'
          % (vosk['engine'], vosk['wer'], vosk['exactHitRate'] * 100, vosk['empty'], vosk['avgRtf']))
    for r in candidates:
        drop = (base - r['wer']) / base if base else 0.0
        r['werDropPct'] = round(drop * 100, 2)
        print('%-32s WER=%.4f  整句全对=%.1f%%  空=%d  RTF=%.4f  相对 vosk 降幅=%.1f%%'
              % (r['engine'], r['wer'], r['exactHitRate'] * 100, r['empty'],
                 r['avgRtf'], drop * 100))

    gate = {
        'baseline': vosk['engine'],
        'baselineWer': base,
        'candidates': [{'engine': r['engine'], 'wer': r['wer'],
                        'werDropPct': r['werDropPct'], 'rtf': r['avgRtf'],
                        'pass': r['werDropPct'] >= 50.0 and r['avgRtf'] < 1.0}
                       for r in candidates],
    }
    gate['anyPass'] = any(c['pass'] for c in gate['candidates'])
    results['gate'] = gate
    print('\n闸门（WER 降幅 ≥50%% 且 RTF <1）：')
    for c in gate['candidates']:
        print('  %-32s 降幅 %+.1f%%  RTF %.3f  → %s'
              % (c['engine'], c['werDropPct'], c['rtf'], '通过' if c['pass'] else '不通过'))

    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    io.open(args.out, 'w', encoding='utf-8').write(
        json.dumps(results, ensure_ascii=False, indent=1) + '\n')
    print('写出：%s' % args.out)
    return 0 if gate['anyPass'] else 1


if __name__ == '__main__':
    sys.exit(main())
