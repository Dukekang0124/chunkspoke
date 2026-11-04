/// ASR-209 · 英语字音转换（g2p）+ 音素串编辑距离。
///
/// 目的：小模型（vosk small）会把同一发音的不同写法转成不同拼写
/// （write/right、there/their、two/too），字符串层永远判不过。
/// 判卷层需要一条**只看发音、不看拼写**的第三通道。
///
/// 纪律：
/// - 纯函数、无依赖、可单测；不联网、不引入新包。
/// - 只做「粗音素」，不追求 IPA 精度：符号是自造的字母集，仅供同串比较。
/// - 阈值不在本文件里拍：由 `release/ASR-209/音素阈值定标.md` 的实测表决定，
///   由 `kPhonRatio` 单点引用（见 speech_judge.dart）。
library;

/// 音素相似比门槛（ASR-209 A 层第三通道）。
///
/// 定标（`test/phonetics_test.dart` 实测表 → `docs/ASR-209-阈值定标.md`）：
///   应放行同音组最低值 = 1.000，应拒绝异音组最高值 = 0.750。
/// 取 0.85 = 拒绝侧 0.75 + 0.10 余量，同时给同音侧留 0.15 余量。
/// 只收「灰带」：真正不同元音的词（snack/snake 0.75）仍被拒。
const double kPhonRatio = 0.85;

const Map<String, String> _exceptions = {
  // 数字/高频虚词（不规则拼写，规则层覆盖不到）
  'one': 'wan', 'two': 'tu', 'three': '0ri', 'four': 'for', 'five': 'fayv',
  'six': 'siks', 'seven': 'sevan', 'eight': 'eyt', 'nine': 'nayn',
  'ten': 'ten', 'eleven': 'elevan', 'twelve': 'twelv', 'twenty': 'twenti',
  'dozen': 'dazan', 'zero': 'ziro',
  'a': 'a', 'an': 'an', 'the': '0e', 'to': 'tu', 'too': 'tu', 'of': 'ov',
  'are': 'ar', 'was': 'waz', 'were': 'wer', 'who': 'hu', 'what': 'wat',
  'where': 'wer', 'there': '0er', 'their': "0er", 'they': '0ey',
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
  // 同音异拼（ASR-209 A 层定标样本）：规则层给不出同一串，必须显式并列。
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
};

/// 口语缩合 → 标准词序列（判卷折叠 + 词级等价共用），两类：
///  ① 连读合并（wanna/gonna…）：ASR 常把两词转成一个口语词；
///  ② **撇号缩合**（i'd / don't / it's…）：`normalizeSpeech` 保留撇号，
///    于是 "I'd like the main course." 的目标 token 是 `i'd`，而识别常给
///    `i would`（两个 token）或只剩 `i`。旧版把 `i'd` 当实词又对不上任何写法，
///    核心词命中率被白压一档 —— ASR-211 案1 的真实根因。
///
/// 键一律小写（进入这里前都已规范化）。多义的 `i'd` 取 `would`（本包语句全是
/// "I'd like/…"）；`wordClose` 走「展开后任一词相等」，所以 `i'd↔i`、`i'd↔would`
/// 都算同一词，不需要猜语义。
const Map<String, List<String>> _spokenContractions = {
  'wanna': ['want', 'to'],
  'gonna': ['going', 'to'],
  'gotta': ['got', 'to'],
  'kinda': ['kind', 'of'],
  'sorta': ['sort', 'of'],
  'dunno': ['do', 'not', 'know'],
  'lemme': ['let', 'me'],
  'gimme': ['give', 'me'],
  'cuz': ['because'],
  'coz': ['because'],
  'cause': ['because'],
  'hafta': ['have', 'to'],
  'oughta': ['ought', 'to'],
  'tryna': ['trying', 'to'],
  'whatcha': ['what', 'are', 'you'],
  'gotcha': ['got', 'you'],
  'betcha': ['bet', 'you'],
  // 撇号缩合（ASR-211）
  "i'd": ['i', 'would'],
  "i'll": ['i', 'will'],
  "i'm": ['i', 'am'],
  "i've": ['i', 'have'],
  "you'd": ['you', 'would'],
  "you'll": ['you', 'will'],
  "you're": ['you', 'are'],
  "you've": ['you', 'have'],
  "he'd": ['he', 'would'],
  "he'll": ['he', 'will'],
  "he's": ['he', 'is'],
  "she'd": ['she', 'would'],
  "she'll": ['she', 'will'],
  "she's": ['she', 'is'],
  "we'd": ['we', 'would'],
  "we'll": ['we', 'will'],
  "we're": ['we', 'are'],
  "we've": ['we', 'have'],
  "they'd": ['they', 'would'],
  "they'll": ['they', 'will'],
  "they're": ['they', 'are'],
  "they've": ['they', 'have'],
  "it's": ['it', 'is'],
  "that's": ['that', 'is'],
  "this's": ['this', 'is'],
  "there's": ['there', 'is'],
  "who's": ['who', 'is'],
  "what's": ['what', 'is'],
  "let's": ['let', 'us'],
  "one's": ['one', 'is'],
  "don't": ['do', 'not'],
  "doesn't": ['does', 'not'],
  "didn't": ['did', 'not'],
  "isn't": ['is', 'not'],
  "aren't": ['are', 'not'],
  "wasn't": ['was', 'not'],
  "weren't": ['were', 'not'],
  "can't": ['can', 'not'],
  "couldn't": ['could', 'not'],
  "shouldn't": ['should', 'not'],
  "wouldn't": ['would', 'not'],
  "won't": ['will', 'not'],
  "mustn't": ['must', 'not'],
  "haven't": ['have', 'not'],
  "hasn't": ['has', 'not'],
  "hadn't": ['had', 'not'],
};

/// 缩合展开；不是缩合词返回 null。
List<String>? spokenExpansion(String token) => _spokenContractions[token];

/// 撇号词干：`i'd`→`i`、`don't`→`don`、`sam's`→`sam`。
/// 用于「所有格/缩合只多了后半截」的等价（`Sam's` vs `Sam`）。
String apostropheStem(String token) {
  final i = token.indexOf("'");
  return i <= 0 ? token : token.substring(0, i);
}

const List<String> _ones = [
  'zero', 'one', 'two', 'three', 'four', 'five', 'six', 'seven', 'eight',
  'nine', 'ten', 'eleven', 'twelve', 'thirteen', 'fourteen', 'fifteen',
  'sixteen', 'seventeen', 'eighteen', 'nineteen',
];
const List<String> _tens = [
  '', '', 'twenty', 'thirty', 'forty', 'fifty', 'sixty', 'seventy',
  'eighty', 'ninety',
];

/// 整数 → 英文数词（0..999999）。用于「数词转词」归一化。
String numberWord(int n) {
  if (n < 20) return _ones[n];
  if (n < 100) {
    final r = n % 10;
    return '${_tens[n ~/ 10]}${r == 0 ? '' : ' ${_ones[r]}'}';
  }
  if (n < 1000) {
    final r = n % 100;
    return '${_ones[n ~/ 100]} hundred${r == 0 ? '' : ' ${numberWord(r)}'}';
  }
  if (n < 1000000) {
    final r = n % 1000;
    return '${numberWord(n ~/ 1000)} thousand${r == 0 ? '' : ' ${numberWord(r)}'}';
  }
  return '$n';
}

/// 数词（阿拉伯数字或英文拼写）→ 数值；无法解析返回 null。
/// 仅用于「2 / two / twenty one」的等价比较，不做算术。
int? numberValueOf(String token) {
  final t = token.trim().toLowerCase();
  if (t.isEmpty) return null;
  if (RegExp(r'^\d+$').hasMatch(t)) return int.tryParse(t);
  var total = 0;
  var current = 0;
  var matched = false;
  for (final p in t.split(RegExp(r'[\s\-]+'))) {
    final oi = _ones.indexOf(p);
    if (oi >= 0) {
      current += oi;
      matched = true;
      continue;
    }
    final ti = _tens.indexOf(p);
    if (ti > 0) {
      current += ti * 10;
      matched = true;
      continue;
    }
    if (p == 'hundred') {
      current = (current == 0 ? 1 : current) * 100;
      matched = true;
      continue;
    }
    if (p == 'thousand') {
      total += (current == 0 ? 1 : current) * 1000;
      current = 0;
      matched = true;
      continue;
    }
    return null;
  }
  return matched ? total + current : null;
}

/// 判卷专用「口语折叠」：数字转词 + wanna/gonna 等缩合展开成标准写法。
///
/// 只用于**比较**，不替换展示文本，也不改变 token 与 UI 的逐词对应关系
/// （judgeSpeech 仍用原 token 产出 targetWords/targetMatched）。
List<String> expandSpokenTokens(List<String> tokens) {
  final out = <String>[];
  for (final t in tokens) {
    final e = _spokenContractions[t];
    if (e != null) {
      out.addAll(e);
      continue;
    }
    if (RegExp(r'^\d+$').hasMatch(t)) {
      out.addAll(numberWord(int.parse(t)).split(' '));
      continue;
    }
    out.add(t);
  }
  return out;
}

/// c/g 的软音条件：后接 e/i/y 才算软音；词尾（空串）是硬音。
bool _softENext(String n) => n.isNotEmpty && 'eiy'.contains(n);

/// 粗音素串：单词 → 自造符号串（小写，只含音素符号）。
String g2p(String word) {
  var w = word.toLowerCase().replaceAll(RegExp(r"[^a-z']"), '');
  w = w.replaceAll("'", '');
  if (w.isEmpty) return '';
  final ex = _exceptions[w];
  if (ex != null) return ex;
  if (w.length <= 1) return w;

  // 词尾静音 e：先记下来，用来把**紧邻它的那个元音**标长。
  // （不能笼统标记「第一个元音」——excite 的长音在 i，不在开头的 e。）
  var longIdx = -1;
  if (w.endsWith('e') &&
      w.length > 2 &&
      !'aeiou'.contains(w[w.length - 2]) &&
      RegExp(r'[aeiou]').hasMatch(w.substring(0, w.length - 2))) {
    w = w.substring(0, w.length - 1);
    for (var k = w.length - 1; k >= 0; k--) {
      if ('aeiou'.contains(w[k])) {
        longIdx = k;
        break;
      }
    }
  }

  final out = StringBuffer();
  var i = 0;
  String next(int k) => (i + k < w.length) ? w[i + k] : '';

  // 词首不发音
  if (w.startsWith('kn') || w.startsWith('gn')) i = 1;
  if (w.startsWith('wr')) i = 1;
  if (w.startsWith('ps')) i = 1;

  bool cAt(String at) => w.startsWith(at, i);

  while (i < w.length) {
    final c = w[i];
    // 三字母组合（长匹配优先）
    if (cAt('tion')) {
      out.write('Sn');
      i += 4;
      continue;
    }
    if (cAt('sion')) {
      out.write('Sn');
      i += 4;
      continue;
    }
    if (cAt('ture')) {
      out.write('Cer');
      i += 4;
      continue;
    }
    if (cAt('ough')) {
      out.write('o');
      i += 4;
      continue;
    }
    if (cAt('ght')) {
      out.write('t');
      i += 3;
      continue;
    }
    if (cAt('igh')) {
      out.write('I');
      i += 3;
      continue;
    }
    // 双字母组合
    if (cAt('th')) {
      out.write('0');
      i += 2;
      continue;
    }
    if (cAt('sh')) {
      out.write('S');
      i += 2;
      continue;
    }
    if (cAt('ch')) {
      out.write('C');
      i += 2;
      continue;
    }
    if (cAt('ph')) {
      out.write('f');
      i += 2;
      continue;
    }
    if (cAt('wh')) {
      out.write('w');
      i += 2;
      continue;
    }
    if (cAt('ck')) {
      out.write('k');
      i += 2;
      continue;
    }
    if (cAt('qu')) {
      out.write('kw');
      i += 2;
      continue;
    }
    if (cAt('ng')) {
      out.write('N');
      i += 2;
      continue;
    }
    if (cAt('gh')) {
      // 其余 gh：多为静音（night 已由 igh/ght 处理后）
      i += 2;
      continue;
    }
    // 元音组合（长元音用大写，与短元音区分，避免 ship/sheep、full/fool 混同）
    if (cAt('ee')) {
      out.write('I');
      i += 2;
      continue;
    }
    if (cAt('ea')) {
      out.write('I');
      i += 2;
      continue;
    }
    if (cAt('oo')) {
      out.write('U');
      i += 2;
      continue;
    }
    if (cAt('ou')) {
      out.write('u');
      i += 2;
      continue;
    }
    if (cAt('ow')) {
      out.write('o');
      i += 2;
      continue;
    }
    if (cAt('ai') || cAt('ay')) {
      out.write('e');
      i += 2;
      continue;
    }
    if (cAt('oa')) {
      out.write('o');
      i += 2;
      continue;
    }
    if (cAt('oi') || cAt('oy')) {
      out.write('oy');
      i += 2;
      continue;
    }
    if (cAt('au') || cAt('aw')) {
      out.write('o');
      i += 2;
      continue;
    }
    if (cAt('ie')) {
      out.write('i');
      i += 2;
      continue;
    }
    if (cAt('ei')) {
      out.write('e');
      i += 2;
      continue;
    }
    if (cAt('ue')) {
      out.write('u');
      i += 2;
      continue;
    }
    if (cAt('ui')) {
      out.write('u');
      i += 2;
      continue;
    }
    if (cAt('ew')) {
      out.write('u');
      i += 2;
      continue;
    }
    // 双写辅音折叠（bb/ll/ss/tt…）
    if (i + 1 < w.length && w[i + 1] == c && !'aeiou'.contains(c)) {
      i += 1;
      continue;
    }

    switch (c) {
      case 'c':
        // 注意 next(1) 可能是空串，而 String.contains('') 恒为 true → 必须先判非空。
        out.write(_softENext(next(1)) ? 's' : 'k');
        break;
      case 'g':
        out.write(_softENext(next(1)) ? 'j' : 'g');
        break;
      case 'x':
        out.write('ks');
        break;
      case 'y':
        // 词首 y 是辅音；其余按元音 i 处理
        out.write(i == 0 ? 'y' : 'i');
        break;
      case 'a':
      case 'e':
      case 'i':
      case 'o':
      case 'u':
        out.write(i == longIdx ? c.toUpperCase() : c);
        break;
      case 'h':
        // 词尾 h 静音（oh 除外，规则层不细究）
        if (i == w.length - 1) break;
        out.write('h');
        break;
      default:
        out.write(c);
    }
    i += 1;
    // 长元音标记只用一次
  }
  return out.toString();
}

/// 音素串相似比：1 - 编辑距离 / 较长长度（0..1）。
double phonemeRatio(String a, String b) {
  final pa = g2p(a);
  final pb = g2p(b);
  if (pa.isEmpty || pb.isEmpty) return 0;
  if (pa == pb) return 1.0;
  final m = pa.length, n = pb.length;
  final dp = List.generate(m + 1, (_) => List.filled(n + 1, 0));
  for (var i = 0; i <= m; i++) {
    dp[i][0] = i;
  }
  for (var j = 0; j <= n; j++) {
    dp[0][j] = j;
  }
  for (var i = 1; i <= m; i++) {
    for (var j = 1; j <= n; j++) {
      final cost = pa[i - 1] == pb[j - 1] ? 0 : 1;
      dp[i][j] = [dp[i - 1][j] + 1, dp[i][j - 1] + 1, dp[i - 1][j - 1] + cost]
          .reduce((x, y) => x < y ? x : y);
    }
  }
  final denom = m > n ? m : n;
  return 1 - dp[m][n] / denom;
}
