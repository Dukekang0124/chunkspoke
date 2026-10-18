# -*- coding: utf-8 -*-
# 发版门禁：用 app 同款 Vosk 模型 + 同款 judgeSpeech 判定，离线测「开口」真实通过率。
# 与 lib/services/speech_judge.dart 保持一致（含内容词加权判定）。改判定必须同步改这里并重跑。
#
# 用法（需先准备模型与语料，见 _internal/xp3-2026-10-17/）：
#   python tools/vosk_sim.py
# 门禁：Zira(标准美音)·正常语速 通过率 <97% 时以非零码退出（拦截发版）。
import io, json, os, sys, wave, collections, re
import vosk
from vosk import Model, SetLogLevel
SetLogLevel(-1)

MODEL_DIR = r'D:\tmp\vosk-model\vosk-model-small-en-us-0.15'
WAV_DIR = r'D:\tmp\tts_wav'
PACK = os.environ.get('CONTENT_PACK', r'assets\content_pack.json')
GATE_MIN_PASS = 0.97

# ---------- 移植 app 判定（speech_judge.dart，含内容词加权） ----------
FUNCTION_WORDS = set('''a an the to of for and or but so if as in on at by with from up down out off
over under about into onto i you he she it we they me him her us them my your his its our their mine
yours hers is am are was were be been being do does did have has had will would shall should can
could may might must not no yes ok okay please this that these those here there what when where who
whom why how which'''.split())
CONFUSION_PAIRS = ({'a', 'an'}, {'the', 'this'}, {'to', 'too'}, {'on', 'in'})


def normalize_speech(s):
    s = s.lower()
    s = re.sub(r"[^a-z0-9' ]", ' ', s)
    s = re.sub(r'\s+', ' ', s).strip()
    return s


def tokenize(s):
    return [w for w in normalize_speech(s).split(' ') if w]


def levenshtein(a, b):
    m, n = len(a), len(b)
    dp = list(range(n + 1))
    for i in range(1, m + 1):
        prev, dp[0] = dp[0], i
        for j in range(1, n + 1):
            cur = dp[j]
            dp[j] = min(dp[j] + 1, dp[j - 1] + 1, prev + (0 if a[i - 1] == b[j - 1] else 1))
            prev = cur
    return dp[n]


def word_close(a, b):
    a, b = normalize_speech(a), normalize_speech(b)
    if not a or not b:
        return False
    if a == b:
        return True
    if any(a in p and b in p for p in CONFUSION_PAIRS):
        return True
    if levenshtein(a, b) <= 1:
        return True
    sh, lo = (a, b) if len(a) <= len(b) else (b, a)
    return lo.startswith(sh) and (len(lo) - len(sh)) <= 1


def is_function(w):
    return w in FUNCTION_WORDS


def weighted_align(rec, tgt):
    n, m = len(rec), len(tgt)
    INF = 1e9

    def dele(w):
        return 0.3 if is_function(w) else 2.0

    def ins(w):
        return 0.2 if is_function(w) else 0.5

    def sub(r, t):
        if word_close(r, t):
            return 0.0
        return 0.3 if (is_function(r) and is_function(t)) else 2.0

    dp = [[INF] * (m + 1) for _ in range(n + 1)]
    dp[0][0] = 0.0
    for i in range(1, n + 1):
        dp[i][0] = dp[i - 1][0] + ins(rec[i - 1])
    for j in range(1, m + 1):
        dp[0][j] = dp[0][j - 1] + dele(tgt[j - 1])
    for i in range(1, n + 1):
        for j in range(1, m + 1):
            dp[i][j] = min(dp[i - 1][j] + ins(rec[i - 1]),
                           dp[i][j - 1] + dele(tgt[j - 1]),
                           dp[i - 1][j - 1] + sub(rec[i - 1], tgt[j - 1]))
    dist = dp[n][m]
    denom = sum(dele(w) for w in tgt)
    wsim = 1.0 if denom == 0 else max(0.0, min(1.0, 1 - dist / denom))

    matched = [False] * m
    i, j = n, m
    while i > 0 and j > 0:
        if abs(dp[i][j] - (dp[i - 1][j - 1] + sub(rec[i - 1], tgt[j - 1]))) < 1e-9:
            if word_close(rec[i - 1], tgt[j - 1]):
                matched[j - 1] = True
            i -= 1
            j -= 1
        elif abs(dp[i][j] - (dp[i - 1][j] + ins(rec[i - 1]))) < 1e-9:
            i -= 1
        else:
            j -= 1

    content = [not is_function(w) for w in tgt]
    total = sum(content)
    hit = sum(1 for k in range(m) if content[k] and matched[k])
    core_hit = 1.0 if total == 0 else hit / total
    return wsim, core_hit, matched


def judge_speech(target, recognized, confidence=None, duration=None, min_dur=0.4):
    tgt = tokenize(target)
    rec = tokenize(recognized)
    if not rec:
        return dict(passed=False, sim=0.0, reason='empty')
    if duration is not None and duration < min_dur:
        return dict(passed=False, sim=0.0, reason='tooShort')
    if len(tgt) == len(rec) and all(a == b for a, b in zip(tgt, rec)):
        return dict(passed=True, sim=1.0, wsim=1.0, core=1.0, reason='exact')
    wsim, core, _ = weighted_align(rec, tgt)
    if core < 0.7:
        return dict(passed=False, sim=wsim, reason='lowCore')
    if wsim < 0.8:
        return dict(passed=False, sim=wsim, reason='lowSim')
    if confidence is not None and confidence < 0.45:
        return dict(passed=False, sim=wsim, reason='lowConf')
    return dict(passed=True, sim=wsim, reason='fuzzy')


def vosk_grammar_words(phrases):
    words = set()
    for p in phrases:
        for w in re.split(r"[^a-z0-9']+", p.lower()):
            if w:
                words.add(w)
    return sorted(words)


# ---------- 识别（与 vosk_engine 同口径：先带语法，空结果回退全模型） ----------
model = Model(MODEL_DIR)


def recognize(wav_path, target):
    wf = wave.open(wav_path, 'rb')
    rate = wf.getframerate()
    dur = wf.getnframes() / rate

    def run(grammar):
        rec = vosk.KaldiRecognizer(model, rate, json.dumps(grammar, ensure_ascii=False)) if grammar \
            else vosk.KaldiRecognizer(model, rate)
        rec.SetWords(False)
        data = wf.readframes(4000)
        while len(data) > 0:
            rec.AcceptWaveform(data)
            data = wf.readframes(4000)
        return json.loads(rec.FinalResult()).get('text', '')

    text = run(vosk_grammar_words([target]))
    if not text.strip():
        wf2 = wave.open(wav_path, 'rb')
        text = run(None)
        wf2.close()
    wf.close()
    return text, dur


# ---------- 主流程 ----------
j = json.load(io.open(PACK, encoding='utf-8'))
tasks = [dict(level=l['id'], target=s['text'], sid=s['id'])
         for l in j['levels'] for s in l.get('sentences', [])]
results = []
files = os.listdir(WAV_DIR)
bysid = collections.defaultdict(list)
for f in files:
    if not f.endswith('.wav'):
        continue
    stem = f[:-4]
    sid, voice, rate = stem.rsplit('_', 2)
    rate = int(rate[1:]) if rate.startswith('r') else int(rate)
    bysid[sid].append((voice, rate, f))

for t in tasks:
    key = t['level'] + '_' + t['sid']
    for voice, rate, f in bysid.get(key, []):
        wav = os.path.join(WAV_DIR, f)
        try:
            text, dur = recognize(wav, t['target'])
        except Exception as e:
            print('RECOG FAIL', f, repr(e))
            text, dur = '', 0
        o = judge_speech(t['target'], text, None, dur)
        results.append(dict(level=t['level'], sid=t['sid'], voice=voice, rate=int(rate),
                            target=t['target'], heard=text, passed=o['passed'], sim=o['sim'],
                            reason=o['reason']))

_out = os.environ.get('RESULTS_OUT') or os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                                     'vosk_sim_results_weighted.json')
out = io.open(_out, 'w', encoding='utf-8')
json.dump(results, out, ensure_ascii=False, indent=1)
out.close()


def agg(rs, label):
    n = len(rs)
    p = sum(1 for r in rs if r['passed'])
    sims = [r['sim'] for r in rs]
    rate = p / n if n else 0.0
    print(f"{label}: n={n} pass={p} ({rate*100:.1f}%) avgSim={sum(sims)/n:.3f}")
    print('   reasons:', dict(collections.Counter(r['reason'] for r in rs)))
    return rate


base = [r for r in results if r['rate'] == 0]
fast = [r for r in results if r['rate'] == 2]
zira = agg([r for r in base if r['voice'].endswith('ZiraDesktop')], '全部487句 · Zira(标准美音) · 正常语速')
agg([r for r in base if r['voice'].endswith('HuihuiDesktop')], '全部487句 · Huihui(中文口音) · 正常语速')
agg(fast, 'A关12句 · 双声音 · 快速语速(rate+2)')

print()
print('== 失败样例（Zira 正常语速，前12） ==')
n = 0
for r in base:
    if r['voice'].endswith('ZiraDesktop') and not r['passed'] and n < 12:
        print(f"  [{r['level']}] 目标: {r['target']}")
        print(f"        听到: '{r['heard']}'  sim={r['sim']:.2f} reason={r['reason']}")
        n += 1

# 发版门禁：清晰语音（标准美音·正常语速）通过率 <97% 拦截发版。
if zira < GATE_MIN_PASS:
    print(f"\n[门禁不通过] Zira 通过率 {zira*100:.1f}% < {GATE_MIN_PASS*100:.0f}%，拦截发版")
    sys.exit(1)
print(f"\n[门禁通过] Zira 通过率 {zira*100:.1f}% ≥ {GATE_MIN_PASS*100:.0f}%")
