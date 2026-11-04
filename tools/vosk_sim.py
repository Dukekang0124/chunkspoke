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
CONFUSION_PAIRS = ({'a', 'an'}, {'the', 'this'}, {'to', 'too'}, {'on', 'in'},
                   {'what', 'that'}, {'what', 'with'}, {'was', 'well'},
                   {'to', 'do'}, {'of', 'off'})

# ASR-209 A 层第三通道的阈值（与 lib/services/phonetics.dart 的 kPhonRatio 同值；
# 定标见 release/ASR-209/音素阈值定标.md）。
PHON_RATIO = 0.85


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


def _relaxed_short_function(a, b):
    if len(a) <= 1 or len(b) <= 1:
        return False
    if len(a) > 4 or len(b) > 4:
        return False
    if a not in FUNCTION_WORDS or b not in FUNCTION_WORDS:
        return False
    return levenshtein(a, b) <= 2


def word_close(a, b):
    a, b = normalize_speech(a), normalize_speech(b)
    if not a or not b:
        return False
    if a == b:
        return True
    if any(a in p and b in p for p in CONFUSION_PAIRS):
        return True
    # ASR-209 A 层归一化：数词等价（2 ↔ two）与口语缩合等价（wanna ↔ want）。
    na, nb = number_value_of(a), number_value_of(b)
    if na is not None and nb is not None and na == nb:
        return True
    ea = CONTRACTIONS.get(a)
    if ea is not None and b in ea.split(' '):
        return True
    eb = CONTRACTIONS.get(b)
    if eb is not None and a in eb.split(' '):
        return True
    # 单字母只认完全相同（含上方混淆对）：否则任意两字母编辑距离都是 1。
    if len(a) == 1 or len(b) == 1:
        return False
    if levenshtein(a, b) <= 1:
        return True
    if _relaxed_short_function(a, b):
        return True
    # ASR-209 A 层第三通道：音素级等价（g2p + 编辑距离）。
    if phoneme_ratio(a, b) >= PHON_RATIO:
        return True
    sh, lo = (a, b) if len(a) <= len(b) else (b, a)
    return lo.startswith(sh) and (len(lo) - len(sh)) <= 1


# ---------- ASR-209 A 层：口语折叠 + 粗音素（与 phonetics.dart 逐字对应） ----------
EXCEPTIONS = {
    'one': 'wan', 'two': 'tu', 'three': '0ri', 'four': 'for', 'five': 'fayv',
    'six': 'siks', 'seven': 'sevan', 'eight': 'eyt', 'nine': 'nayn',
    'ten': 'ten', 'eleven': 'elevan', 'twelve': 'twelv', 'twenty': 'twenti',
    'dozen': 'dazan', 'zero': 'ziro',
    'a': 'a', 'an': 'an', 'the': '0e', 'to': 'tu', 'too': 'tu', 'of': 'ov',
    'are': 'ar', 'was': 'waz', 'were': 'wer', 'who': 'hu', 'what': 'wat',
    'where': 'wer', 'there': '0er', 'their': '0er', 'they': '0ey',
    'here': 'hir', 'your': 'yor', 'you': 'yu', 'our': 'awer',
    'said': 'sed', 'says': 'sez', 'does': 'duz', 'done': 'dan',
    'come': 'kam', 'some': 'sam', 'love': 'lav', 'give': 'giv',
    'have': 'hav', 'live': 'liv', 'move': 'muv', 'gone': 'gon',
    'could': 'kud', 'would': 'wud', 'should': 'Sud', 'been': 'bin',
    'friend': 'frend', 'people': 'pepal', 'because': 'bikoz',
    'busy': 'bizi', 'minute': 'minit', 'island': 'ayland',
    'listen': 'lisan', 'answer': 'anser', 'know': 'no', 'knife': 'nayf',
    'write': 'rayt', 'right': 'rayt', 'night': 'nayt', 'light': 'layt',
    'great': 'greyt', 'break': 'breyk', 'read': 'rid', 'bread': 'bred',
    'head': 'hed', 'money': 'mani', 'many': 'meni', 'any': 'eni',
    'again': 'agen', 'half': 'haf', 'talk': 'tok', 'walk': 'wok',
    'small': 'smol', 'call': 'kol', 'all': 'ol', 'ball': 'bol',
    'door': 'dor', 'floor': 'flor', 'word': 'werd', 'work': 'werk',
    'world': 'werld', 'learn': 'lern', 'early': 'erli', 'heart': 'hart',
    'laugh': 'laf', 'enough': 'inaf', 'tough': 'taf', 'through': '0ru',
    'though': '0o', 'thought': '0ot', 'bought': 'bot', 'brought': 'brot',
    'caught': 'kot', 'taught': 'tot', 'daughter': 'doter',
    'quiet': 'kwayet', 'quite': 'kwayt', 'question': 'kwesCan',
    'sure': 'Sur', 'sugar': 'Suger', 'usually': 'yuZuali',
    'water': 'woter', 'mother': 'ma0er', 'father': 'fa0er',
    'brother': 'bra0er', 'weather': 'we0er', 'together': 'tuge0er',
    'woman': 'wuman', 'women': 'wimin',
    'pizza': 'pitsa', 'coffee': 'kofi', 'menu': 'menyu',
    'restaurant': 'restarant', 'receipt': 'risit', 'hour': 'awer',
    'iron': 'ayeron', 'science': 'sayens',
    # 同音异拼（ASR-209 A 层定标样本）
    'won': 'wan', 'hear': 'hir', 'piece': 'pis', 'peace': 'pis',
    'whether': 'we0er', 'whole': 'hol', 'hole': 'hol', 'wood': 'wud',
    'plain': 'pleyn', 'plane': 'pleyn', 'son': 'sun',
    'weight': 'weyt', 'wait': 'weyt', 'wear': 'wer',
    'find': 'faynd', 'fined': 'faynd', 'mind': 'maynd', 'kind': 'kaynd',
    'which': 'wiC', 'witch': 'wiC', 'brake': 'breyk',
    'fair': 'fer', 'fare': 'fer', 'tale': 'tel', 'knight': 'nayt',
    'flour': 'flawer', 'flower': 'flawer',
    'allowed': 'alawd', 'aloud': 'alawd', 'made': 'meyd', 'maid': 'meyd',
    'buy': 'bay', 'by': 'bay', 'bye': 'bay', 'coat': 'kowt',
    'theyre': '0er', 'youre': 'yor',
}

CONTRACTIONS = {
    'wanna': 'want to',
    'gonna': 'going to',
    'gotta': 'got to',
    'kinda': 'kind of',
    'sorta': 'sort of',
    'dunno': 'do not know',
    'lemme': 'let me',
    'gimme': 'give me',
    'cuz': 'because',
    'coz': 'because',
    'cause': 'because',
    'hafta': 'have to',
    'oughta': 'ought to',
    'tryna': 'trying to',
    'whatcha': 'what are you',
    'gotcha': 'got you',
    'betcha': 'bet you',
}

_ONES = ['zero', 'one', 'two', 'three', 'four', 'five', 'six', 'seven',
         'eight', 'nine', 'ten', 'eleven', 'twelve', 'thirteen', 'fourteen',
         'fifteen', 'sixteen', 'seventeen', 'eighteen', 'nineteen']
_TENS = ['', '', 'twenty', 'thirty', 'forty', 'fifty', 'sixty', 'seventy',
         'eighty', 'ninety']


def number_word(n):
    if n < 20:
        return _ONES[n]
    if n < 100:
        r = n % 10
        return _TENS[n // 10] + ('' if r == 0 else ' ' + _ONES[r])
    if n < 1000:
        r = n % 100
        return _ONES[n // 100] + ' hundred' + ('' if r == 0 else ' ' + number_word(r))
    if n < 1000000:
        r = n % 1000
        return number_word(n // 1000) + ' thousand' + ('' if r == 0 else ' ' + number_word(r))
    return str(n)


def number_value_of(token):
    t = token.strip().lower()
    if not t:
        return None
    if re.fullmatch(r'\d+', t):
        return int(t)
    total = current = 0
    matched = False
    for p in re.split(r'[\s\-]+', t):
        if p in _ONES:
            current += _ONES.index(p)
            matched = True
            continue
        if p in _TENS and _TENS.index(p) > 0:
            current += _TENS.index(p) * 10
            matched = True
            continue
        if p == 'hundred':
            current = (1 if current == 0 else current) * 100
            matched = True
            continue
        if p == 'thousand':
            total += (1 if current == 0 else current) * 1000
            current = 0
            matched = True
            continue
        return None
    return total + current if matched else None


def expand_spoken_tokens(tokens):
    """只用于比较的口语折叠：缩合展开 + 纯数字转英文数词。"""
    out = []
    for t in tokens:
        e = CONTRACTIONS.get(t)
        if e is not None:
            out.extend(e.split(' '))
            continue
        if re.fullmatch(r'\d+', t):
            out.extend(number_word(int(t)).split(' '))
            continue
        out.append(t)
    return out


def _soft_e_next(n):
    return bool(n) and n in 'eiy'


def g2p(word):
    w = re.sub(r"[^a-z']", '', word.lower()).replace("'", '')
    if not w:
        return ''
    ex = EXCEPTIONS.get(w)
    if ex is not None:
        return ex
    if len(w) <= 1:
        return w

    # 词尾静音 e：把紧邻它的那个元音标长（excite 的长音在 i，不在开头 e）。
    long_idx = -1
    if w.endswith('e') and len(w) > 2 and w[-2] not in 'aeiou' \
            and re.search(r'[aeiou]', w[:-2]):
        w = w[:-1]
        for k in range(len(w) - 1, -1, -1):
            if w[k] in 'aeiou':
                long_idx = k
                break

    out = []
    i = 0

    def nxt(k):
        return w[i + k] if i + k < len(w) else ''

    def cat(at):
        return w.startswith(at, i)

    if w.startswith('kn') or w.startswith('gn'):
        i = 1
    if w.startswith('wr'):
        i = 1
    if w.startswith('ps'):
        i = 1

    while i < len(w):
        c = w[i]
        if cat('tion') or cat('sion'):
            out.append('Sn')
            i += 4
            continue
        if cat('ture'):
            out.append('Cer')
            i += 4
            continue
        if cat('ough'):
            out.append('o')
            i += 4
            continue
        if cat('ght'):
            out.append('t')
            i += 3
            continue
        if cat('igh'):
            out.append('I')
            i += 3
            continue
        if cat('th'):
            out.append('0')
            i += 2
            continue
        if cat('sh'):
            out.append('S')
            i += 2
            continue
        if cat('ch'):
            out.append('C')
            i += 2
            continue
        if cat('ph'):
            out.append('f')
            i += 2
            continue
        if cat('wh'):
            out.append('w')
            i += 2
            continue
        if cat('ck'):
            out.append('k')
            i += 2
            continue
        if cat('qu'):
            out.append('kw')
            i += 2
            continue
        if cat('ng'):
            out.append('N')
            i += 2
            continue
        if cat('gh'):
            i += 2
            continue
        if cat('ee') or cat('ea'):
            out.append('I')
            i += 2
            continue
        if cat('oo'):
            out.append('U')
            i += 2
            continue
        if cat('ou'):
            out.append('u')
            i += 2
            continue
        if cat('ow'):
            out.append('o')
            i += 2
            continue
        if cat('ai') or cat('ay'):
            out.append('e')
            i += 2
            continue
        if cat('oa'):
            out.append('o')
            i += 2
            continue
        if cat('oi') or cat('oy'):
            out.append('oy')
            i += 2
            continue
        if cat('au') or cat('aw'):
            out.append('o')
            i += 2
            continue
        if cat('ie'):
            out.append('i')
            i += 2
            continue
        if cat('ei'):
            out.append('e')
            i += 2
            continue
        if cat('ue') or cat('ui') or cat('ew'):
            out.append('u')
            i += 2
            continue
        # 双写辅音折叠
        if i + 1 < len(w) and w[i + 1] == c and c not in 'aeiou':
            i += 1
            continue

        if c == 'c':
            out.append('s' if _soft_e_next(nxt(1)) else 'k')
        elif c == 'g':
            out.append('j' if _soft_e_next(nxt(1)) else 'g')
        elif c == 'x':
            out.append('ks')
        elif c == 'y':
            out.append('y' if i == 0 else 'i')
        elif c in 'aeiou':
            out.append(c.upper() if i == long_idx else c)
        elif c == 'h':
            if i != len(w) - 1:
                out.append('h')
        else:
            out.append(c)
        i += 1
    return ''.join(out)


def phoneme_ratio(a, b):
    pa, pb = g2p(a), g2p(b)
    if not pa or not pb:
        return 0.0
    if pa == pb:
        return 1.0
    m, n = len(pa), len(pb)
    dp = list(range(n + 1))
    for i in range(1, m + 1):
        prev, dp[0] = dp[0], i
        for j in range(1, n + 1):
            cur = dp[j]
            dp[j] = min(dp[j] + 1, dp[j - 1] + 1,
                        prev + (0 if pa[i - 1] == pb[j - 1] else 1))
            prev = cur
    return 1 - dp[n] / max(m, n)


def _contains_token_window(rec, tgt):
    if not tgt or len(tgt) > len(rec):
        return False
    for i in range(len(rec) - len(tgt) + 1):
        if rec[i:i + len(tgt)] == tgt:
            return True
    return False


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


def judge_speech(target, recognized, confidence=None, duration=None, min_dur=0.4,
                 min_similarity=0.5):
    tgt = tokenize(target)
    rec = tokenize(recognized)
    tgt_fold = expand_spoken_tokens(tgt)
    rec_fold = expand_spoken_tokens(rec)
    if not rec:
        return dict(passed=False, sim=0.0, reason='empty')
    if duration is not None and duration < min_dur:
        return dict(passed=False, sim=0.0, reason='tooShort')
    # 完全匹配：原文逐词一致，或折叠后（数字/缩合）逐词一致。
    if tgt == rec or tgt_fold == rec_fold:
        return dict(passed=True, sim=1.0, wsim=1.0, core=1.0, reason='exact')
    # 包含通道（ASR-209 A 层第一通道）：识别里有一整段与目标逐词相同。
    if _contains_token_window(rec_fold, tgt_fold):
        return dict(passed=True, sim=1.0, wsim=1.0, core=1.0,
                    reason='fuzzy', layer='containment')
    wsim, core, _matched = weighted_align(rec, tgt)
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
