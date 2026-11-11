/// 词块联动 · 提取器（纯函数，零 I/O）。
///
/// 只做一件事：从用户自己存进「我的英语本」的**英文句子**里，找出可以
/// 纳入系统学习的短语（动词短语 / 固定搭配 / 介词短语 / 常用句型）。
///
/// 质量取向 = 宁缺毋滥：
///  · 来源只有两类——内置短语词表 + 一个受控句型模板（be + adj + prep）；
///  · 不做通用 n-gram 统计、不猜词义、不生成中文释义；
///  · 句子不够英文（不足 3 个拉丁词）或全是网址 / 中文时返回空，
///    界面如实显示 0，绝不硬造一个「词块」。
///
/// 这条边界是产品诚实口径的一部分：提取失败不是错误，是「这句话里没有
/// 我认得的可学短语」。以后要扩词表可以，但不能放宽成「碰巧相邻就收」。
library;

/// 每句最多提取几个词块。超过就只留最靠前的几个，避免一句长文刷出十几个
/// 「词块」把词块库淹没（宁可少收，不可滥收）。
const int kClipMaxChunksPerSentence = 4;

/// 一个从句子里抽出的词块。
class ClipChunkHit {
  /// 用于展示与去重的**规范形**（如 looking forward to → look forward to）。
  final String text;

  /// 归一化键（小写、单空格），跨句去重靠它。
  final String key;

  /// 类型：动词短语 / 固定搭配 / 介词短语 / 常用句型。
  final String kind;

  /// 在句子 token 序列里的起点（含）。
  final int start;

  /// 终点（不含）。
  final int end;

  const ClipChunkHit({
    required this.text,
    required this.key,
    required this.kind,
    required this.start,
    required this.end,
  });

  @override
  String toString() => '$text($kind)';
}

/// 提取入口。返回顺序 = 句内出现顺序，已去重、已去重叠。
List<ClipChunkHit> extractClipChunks(String sentence) {
  final toks = _tokenize(sentence);
  if (toks.length < 3) return const [];
  final hits = <ClipChunkHit>[];
  final seen = <String>{};
  var i = 0;
  while (i < toks.length && hits.length < kClipMaxChunksPerSentence) {
    final hit = _hitAt(toks, i);
    if (hit == null) {
      i++;
      continue;
    }
    if (seen.add(hit.key)) hits.add(hit);
    // 无论是否新收，都跳过整段，避免「look forward to」再拆出「forward to」。
    i = hit.end;
  }
  return hits;
}

/// 只对「像英文句子」的文本生效：至少 3 个拉丁词、至少 6 个字母。
///
/// 中文、表情、纯网址、单复数词、CSV 片段（a,b,c）都会在这里被挡掉。
bool looksLikeEnglishSentence(String text) {
  final toks = _tokenize(text);
  if (toks.length < 3) return false;
  var letters = 0;
  for (final t in toks) {
    letters += t.lower.length;
  }
  return letters >= 6;
}

/// 句子归一化（用于「同一句话只算一次」）。
String normalizeClipSentence(String text) {
  final t = text
      .toLowerCase()
      .replaceAll('’', "'")
      .replaceAll(RegExp(r"[^a-z0-9']+"), ' ')
      .trim();
  return t.replaceAll(RegExp(r'\s+'), ' ');
}

// ---------------------------------------------------------------------------
// 分词与归一
// ---------------------------------------------------------------------------

class _Tok {
  const _Tok(this.raw, this.lower);
  final String raw;
  final String lower;
}

final RegExp _kUrlRe = RegExp(r'https?://\S+', caseSensitive: false);
final RegExp _kEmailRe =
    RegExp(r'\b[\w.+-]+@[\w-]+\.[\w.]+\b', caseSensitive: false);
final RegExp _kWordRe = RegExp(r'[A-Za-z]+(?:-[A-Za-z]+)*');

String _stripNoise(String s) => s
    .replaceAll(_kUrlRe, ' ')
    .replaceAll(RegExp(r'www\.\S+', caseSensitive: false), ' ')
    .replaceAll(_kEmailRe, ' ');

/// 缩写展开：把 I'm / she's / don't 摊成两个词，be 句型与动词变位才认得出。
///
/// 只做匹配前处理，不改变存档里的原句；扩展过度（所有格 's → is）最多
/// 让某句少匹配一个词块，不会产生错误的词块。
String _expandContractions(String s) {
  var t = s.replaceAll('’', "'");
  t = t.replaceAllMapped(
      RegExp(r"\bwon't\b", caseSensitive: false), (_) => 'will not');
  t = t.replaceAllMapped(
      RegExp(r"\bshan't\b", caseSensitive: false), (_) => 'shall not');
  t = t.replaceAllMapped(
      RegExp(r"\bcan't\b", caseSensitive: false), (_) => 'can not');
  t = t.replaceAllMapped(
      RegExp(r"\bcannot\b", caseSensitive: false), (_) => 'can not');
  t = t.replaceAllMapped(
      RegExp(r"(\w)n't\b", caseSensitive: false), (m) => '${m[1]} not');
  t = t.replaceAllMapped(
      RegExp(r"(\w)'re\b", caseSensitive: false), (m) => '${m[1]} are');
  t = t.replaceAllMapped(
      RegExp(r"(\w)'m\b", caseSensitive: false), (m) => '${m[1]} am');
  t = t.replaceAllMapped(
      RegExp(r"(\w)'ve\b", caseSensitive: false), (m) => '${m[1]} have');
  t = t.replaceAllMapped(
      RegExp(r"(\w)'ll\b", caseSensitive: false), (m) => '${m[1]} will');
  t = t.replaceAllMapped(
      RegExp(r"(\w)'d\b", caseSensitive: false), (m) => '${m[1]} would');
  t = t.replaceAllMapped(
      RegExp(r"(\w)'s\b", caseSensitive: false), (m) => '${m[1]} is');
  return t;
}

List<_Tok> _tokenize(String text) {
  final prepared = _expandContractions(_stripNoise(text));
  final out = <_Tok>[];
  for (final m in _kWordRe.allMatches(prepared)) {
    final raw = m.group(0)!;
    out.add(_Tok(raw, raw.toLowerCase()));
  }
  return out;
}

String _norm(String s) => s.toLowerCase().replaceAll(RegExp(r'\s+'), ' ');

// ---------------------------------------------------------------------------
// 词表与索引
// ---------------------------------------------------------------------------

const Set<String> _kBeForms = {
  'be', 'is', 'am', 'are', 'was', 'were', 'been', 'being',
};

const Set<String> _kBeAdjs = {
  'able', 'afraid', 'ready', 'happy', 'sorry', 'sure', 'likely', 'glad',
  'willing', 'proud', 'interested', 'excited', 'worried', 'famous', 'full',
  'different', 'similar', 'busy', 'careful', 'good', 'bad', 'angry',
  'surprised', 'tired', 'free', 'kind', 'nice', 'important', 'necessary',
  'possible', 'impossible', 'easy', 'hard', 'difficult', 'safe', 'wrong',
  'right', 'late', 'early',
};

const Set<String> _kAdjPreps = {'to', 'of', 'in', 'at', 'for', 'with', 'about', 'from'};

const Set<String> _kAdverbs = {'really', 'very', 'so', 'quite', 'always', 'usually', 'often'};

/// 内置短语表。键 = 规范形（展示用），值 = 类型。
///
/// 只收「高频、可独立成块、换掉就说不地道」的组合；不收 "go to"、"in the"
/// 这类换个名词就成另一句的框架词。
const Map<String, String> _kPhrases = {
  // —— 动词短语 ——
  'look forward to': '动词短语',
  'look after': '动词短语',
  'look for': '动词短语',
  'look at': '动词短语',
  'look up': '动词短语',
  'look into': '动词短语',
  'look out': '动词短语',
  'look around': '动词短语',
  'give up': '动词短语',
  'give back': '动词短语',
  'give away': '动词短语',
  'give in': '动词短语',
  'give out': '动词短语',
  'take care of': '动词短语',
  'take off': '动词短语',
  'take on': '动词短语',
  'take over': '动词短语',
  'take up': '动词短语',
  'take part in': '动词短语',
  'take place': '动词短语',
  'take away': '动词短语',
  'take out': '动词短语',
  'take back': '动词短语',
  'take a look': '动词短语',
  'take a break': '动词短语',
  'take a walk': '动词短语',
  'take a shower': '动词短语',
  'take a seat': '动词短语',
  'take time': '动词短语',
  'take turns': '动词短语',
  'take it easy': '动词短语',
  'take care': '动词短语',
  'take notes': '动词短语',
  'get up': '动词短语',
  'get on': '动词短语',
  'get off': '动词短语',
  'get in': '动词短语',
  'get out': '动词短语',
  'get along with': '动词短语',
  'get ready for': '动词短语',
  'get rid of': '动词短语',
  'get back': '动词短语',
  'get together': '动词短语',
  'get through': '动词短语',
  'get used to': '动词短语',
  'get in touch': '动词短语',
  'get home': '动词短语',
  'go on': '动词短语',
  'go out': '动词短语',
  'go back': '动词短语',
  'go over': '动词短语',
  'go through': '动词短语',
  'go up': '动词短语',
  'go down': '动词短语',
  'go away': '动词短语',
  'go ahead': '动词短语',
  'go home': '动词短语',
  'go to work': '动词短语',
  'go to school': '动词短语',
  'go to bed': '动词短语',
  'go shopping': '动词短语',
  'come back': '动词短语',
  'come in': '动词短语',
  'come out': '动词短语',
  'come up': '动词短语',
  'come over': '动词短语',
  'come across': '动词短语',
  'come along': '动词短语',
  'come home': '动词短语',
  'put on': '动词短语',
  'put off': '动词短语',
  'put away': '动词短语',
  'put down': '动词短语',
  'put up with': '动词短语',
  'put out': '动词短语',
  'put together': '动词短语',
  'put aside': '动词短语',
  'turn on': '动词短语',
  'turn off': '动词短语',
  'turn up': '动词短语',
  'turn down': '动词短语',
  'turn around': '动词短语',
  'turn out': '动词短语',
  'turn into': '动词短语',
  'pick up': '动词短语',
  'pick out': '动词短语',
  'drop off': '动词短语',
  'drop by': '动词短语',
  'find out': '动词短语',
  'figure out': '动词短语',
  'work out': '动词短语',
  'work on': '动词短语',
  'run out of': '动词短语',
  'run into': '动词短语',
  'run away': '动词短语',
  'set up': '动词短语',
  'set off': '动词短语',
  'set out': '动词短语',
  'break down': '动词短语',
  'break up': '动词短语',
  'break into': '动词短语',
  'bring up': '动词短语',
  'bring back': '动词短语',
  'call off': '动词短语',
  'call back': '动词短语',
  'carry on': '动词短语',
  'carry out': '动词短语',
  'check in': '动词短语',
  'check out': '动词短语',
  'clean up': '动词短语',
  'cut down': '动词短语',
  'cut off': '动词短语',
  'deal with': '动词短语',
  'depend on': '动词短语',
  'belong to': '动词短语',
  'listen to': '动词短语',
  'talk about': '动词短语',
  'talk to': '动词短语',
  'speak to': '动词短语',
  'speak up': '动词短语',
  'think about': '动词短语',
  'think of': '动词短语',
  'think over': '动词短语',
  'wait for': '动词短语',
  'ask for': '动词短语',
  'pay for': '动词短语',
  'pay back': '动词短语',
  'care about': '动词短语',
  'focus on': '动词短语',
  'apply for': '动词短语',
  'agree with': '动词短语',
  'arrive at': '动词短语',
  'believe in': '动词短语',
  'come from': '动词短语',
  'dream of': '动词短语',
  'hear from': '动词短语',
  'hear about': '动词短语',
  'laugh at': '动词短语',
  'meet up': '动词短语',
  'move on': '动词短语',
  'move in': '动词短语',
  'move out': '动词短语',
  'point out': '动词短语',
  'rely on': '动词短语',
  'result in': '动词短语',
  'show up': '动词短语',
  'stay up': '动词短语',
  'stay in': '动词短语',
  'try on': '动词短语',
  'try out': '动词短语',
  'wake up': '动词短语',
  'warm up': '动词短语',
  'wrap up': '动词短语',
  'write down': '动词短语',
  'log in': '动词短语',
  'log out': '动词短语',
  'sign in': '动词短语',
  'sign up': '动词短语',
  'slow down': '动词短语',
  'speed up': '动词短语',
  'stand up': '动词短语',
  'sit down': '动词短语',
  'lie down': '动词短语',
  'calm down': '动词短语',
  'hang out': '动词短语',
  'hang on': '动词短语',
  'hold on': '动词短语',
  'hold up': '动词短语',
  'hurry up': '动词短语',
  'keep on': '动词短语',
  'keep up': '动词短语',
  'knock on': '动词短语',
  'pass away': '动词短语',
  'pass on': '动词短语',
  'pull over': '动词短语',
  'send back': '动词短语',
  'shut down': '动词短语',
  'sort out': '动词短语',
  'throw away': '动词短语',
  'tidy up': '动词短语',
  'watch out': '动词短语',
  'end up': '动词短语',
  'fill in': '动词短语',
  'fill out': '动词短语',
  'hand in': '动词短语',
  'hand out': '动词短语',
  'grow up': '动词短语',
  'cheer up': '动词短语',
  'back up': '动词短语',
  'keep in touch': '动词短语',
  'pay attention to': '动词短语',

  // —— 固定搭配 ——
  'as soon as': '固定搭配',
  'as long as': '固定搭配',
  'as well as': '固定搭配',
  'as usual': '固定搭配',
  'at least': '固定搭配',
  'at most': '固定搭配',
  'at first': '固定搭配',
  'at last': '固定搭配',
  'at once': '固定搭配',
  'at all': '固定搭配',
  'at the same time': '固定搭配',
  'at the end of': '固定搭配',
  'at the beginning of': '固定搭配',
  'at the moment': '固定搭配',
  'at the end': '固定搭配',
  'at the start': '固定搭配',
  'in fact': '固定搭配',
  'in order to': '固定搭配',
  'in the end': '固定搭配',
  'in front of': '固定搭配',
  'in the middle of': '固定搭配',
  'in case': '固定搭配',
  'in general': '固定搭配',
  'in common': '固定搭配',
  'in time': '固定搭配',
  'in addition': '固定搭配',
  'in short': '固定搭配',
  'in total': '固定搭配',
  'in public': '固定搭配',
  'in private': '固定搭配',
  'in person': '固定搭配',
  'in advance': '固定搭配',
  'in detail': '固定搭配',
  'in English': '固定搭配',
  'in touch': '固定搭配',
  'in the past': '固定搭配',
  'in the future': '固定搭配',
  'in the beginning': '固定搭配',
  'on time': '固定搭配',
  'on the way': '固定搭配',
  'on purpose': '固定搭配',
  'on average': '固定搭配',
  'on sale': '固定搭配',
  'on foot': '固定搭配',
  'on board': '固定搭配',
  'on the other hand': '固定搭配',
  'by the way': '固定搭配',
  'by mistake': '固定搭配',
  'by chance': '固定搭配',
  'by hand': '固定搭配',
  'by heart': '固定搭配',
  'by bus': '固定搭配',
  'by car': '固定搭配',
  'by train': '固定搭配',
  'by plane': '固定搭配',
  'for example': '固定搭配',
  'for instance': '固定搭配',
  'for free': '固定搭配',
  'for sure': '固定搭配',
  'for now': '固定搭配',
  'of course': '固定搭配',
  'out of': '固定搭配',
  'up to': '固定搭配',
  'so far': '固定搭配',
  'such as': '固定搭配',
  'thanks to': '固定搭配',
  'according to': '固定搭配',
  'instead of': '固定搭配',
  'because of': '固定搭配',
  'due to': '固定搭配',
  'except for': '固定搭配',
  'rather than': '固定搭配',
  'more than': '固定搭配',
  'less than': '固定搭配',
  'no longer': '固定搭配',
  'not only': '固定搭配',
  'once again': '固定搭配',
  'right away': '固定搭配',
  'right now': '固定搭配',
  'all right': '固定搭配',
  'a lot of': '固定搭配',
  'a little': '固定搭配',
  'a few': '固定搭配',
  'a bit': '固定搭配',
  'a couple of': '固定搭配',
  'plenty of': '固定搭配',
  'kind of': '固定搭配',
  'sort of': '固定搭配',
  'each other': '固定搭配',
  'one another': '固定搭配',
  'make sure': '固定搭配',
  'make sense': '固定搭配',
  'make friends': '固定搭配',
  'make a difference': '固定搭配',
  'make a decision': '固定搭配',
  'make a mistake': '固定搭配',
  'make money': '固定搭配',
  'make progress': '固定搭配',
  'have fun': '固定搭配',
  'have a look': '固定搭配',
  'have a good time': '固定搭配',
  'have a try': '固定搭配',
  'have a drink': '固定搭配',
  'have a meal': '固定搭配',
  'do homework': '固定搭配',
  'do business': '固定搭配',
  'do a favor': '固定搭配',
  'would like': '固定搭配',
  'would love': '固定搭配',
  'would like to': '固定搭配',
  'would love to': '固定搭配',
  'had better': '固定搭配',
  'have to': '固定搭配',
  'used to': '固定搭配',

  // —— 介词短语（时间 / 地点） ——
  'in the morning': '介词短语',
  'in the afternoon': '介词短语',
  'in the evening': '介词短语',
  'at night': '介词短语',
  'at noon': '介词短语',
  'on Monday': '介词短语',
  'on weekends': '介词短语',
  'on the weekend': '介词短语',
  'every day': '介词短语',
  'every week': '介词短语',
  'every month': '介词短语',
  'every year': '介词短语',
  'next week': '介词短语',
  'next month': '介词短语',
  'next year': '介词短语',
  'last week': '介词短语',
  'last month': '介词短语',
  'last year': '介词短语',
  'this morning': '介词短语',
  'this afternoon': '介词短语',
  'this evening': '介词短语',
  'tomorrow morning': '介词短语',
  'yesterday morning': '介词短语',
  'all day': '介词短语',
  'all night': '介词短语',
  'all the time': '介词短语',
  'in a row': '介词短语',
  'at home': '介词短语',
  'at work': '介词短语',
  'at school': '介词短语',
  'at the airport': '介词短语',
  'at the station': '介词短语',
  'in the car': '介词短语',
  'on the bus': '介词短语',
  'on the train': '介词短语',
  'in town': '介词短语',
  'in the city': '介词短语',

  // —— 常用句型（be + adj + prep） ——
  'be able to': '常用句型',
  'be afraid of': '常用句型',
  'be interested in': '常用句型',
  'be good at': '常用句型',
  'be proud of': '常用句型',
  'be ready to': '常用句型',
  'be ready for': '常用句型',
  'be sorry for': '常用句型',
  'be sure of': '常用句型',
  'be sure to': '常用句型',
  'be worried about': '常用句型',
  'be excited about': '常用句型',
  'be famous for': '常用句型',
  'be full of': '常用句型',
  'be different from': '常用句型',
  'be similar to': '常用句型',
  'be busy with': '常用句型',
  'be careful with': '常用句型',
  'be happy to': '常用句型',
  'be glad to': '常用句型',
  'be willing to': '常用句型',
  'be likely to': '常用句型',
  'be supposed to': '常用句型',
  'be used to': '常用句型',
  'be going to': '常用句型',
  'be about to': '常用句型',
  'be up to': '常用句型',
  'be good for': '常用句型',
  'be bad for': '常用句型',
  'be angry with': '常用句型',
  'be surprised at': '常用句型',
  'be tired of': '常用句型',
  'be free to': '常用句型',
  'be kind to': '常用句型',
  'be nice to': '常用句型',
  'be important to': '常用句型',
  'be necessary to': '常用句型',
  'be possible to': '常用句型',
  'be easy to': '常用句型',
  'be hard to': '常用句型',
  'be difficult to': '常用句型',
  'be safe to': '常用句型',
};

/// 不规则动词（只收词表里真正用到的第一词）。
const Map<String, List<String>> _kIrregular = {
  'give': ['gave', 'given', 'giving', 'gives'],
  'take': ['took', 'taken', 'taking', 'takes'],
  'get': ['got', 'gotten', 'getting', 'gets'],
  'go': ['went', 'gone', 'going', 'goes'],
  'come': ['came', 'coming', 'comes'],
  'put': ['putting', 'puts'],
  'find': ['found', 'finding', 'finds'],
  'run': ['ran', 'running', 'runs'],
  'set': ['setting', 'sets'],
  'break': ['broke', 'broken', 'breaking', 'breaks'],
  'bring': ['brought', 'bringing', 'brings'],
  'keep': ['kept', 'keeping', 'keeps'],
  'hold': ['held', 'holding', 'holds'],
  'pay': ['paid', 'paying', 'pays'],
  'think': ['thought', 'thinking', 'thinks'],
  'speak': ['spoke', 'spoken', 'speaking', 'speaks'],
  'stand': ['stood', 'standing', 'stands'],
  'sit': ['sat', 'sitting', 'sits'],
  'meet': ['met', 'meeting', 'meets'],
  'send': ['sent', 'sending', 'sends'],
  'hear': ['heard', 'hearing', 'hears'],
  'deal': ['dealt', 'dealing', 'deals'],
  'lie': ['lay', 'lain', 'lying', 'lies'],
  'hang': ['hung', 'hanging', 'hangs'],
  'throw': ['threw', 'thrown', 'throwing', 'throws'],
  'write': ['wrote', 'written', 'writing', 'writes'],
  'fall': ['fell', 'fallen', 'falling', 'falls'],
  'cut': ['cutting', 'cuts'],
  'shut': ['shutting', 'shuts'],
  'wake': ['woke', 'woken', 'waking', 'wakes'],
  'make': ['made', 'making', 'makes'],
  'have': ['has', 'had', 'having'],
  'do': ['does', 'did', 'done', 'doing'],
  'see': ['saw', 'seen', 'seeing', 'sees'],
};

/// 不需要生成变形（虚词开头；短语本身已固定）。
const Set<String> _kNoVariantFirsts = {
  'the', 'a', 'an', 'to', 'in', 'on', 'at', 'of', 'for', 'with', 'by', 'as',
  'up', 'out', 'off', 'away', 'back', 'all', 'more', 'less', 'each', 'one',
  'no', 'not', 'so', 'such', 'than', 'kind', 'sort', 'plenty', 'right',
  'be',
};

class _Phrase {
  final List<String> rest;
  final String canonical;
  final String kind;
  const _Phrase(this.rest, this.canonical, this.kind);
}

final Map<String, List<_Phrase>> _kIndex = _buildIndex();

Map<String, List<_Phrase>> _buildIndex() {
  final out = <String, List<_Phrase>>{};
  void add(String first) {
    // 占位，实际在下面统一填。
    out.putIfAbsent(first, () => <_Phrase>[]);
  }

  _kPhrases.forEach((phrase, kind) {
    final canonicalToks = phrase.split(' ');
    final first = canonicalToks.first.toLowerCase();
    final rest = canonicalToks.sublist(1).map((s) => s.toLowerCase()).toList();
    for (final variant in _firstVariants(first)) {
      add(variant);
      out[variant]!.add(_Phrase(rest, phrase, kind));
    }
  });
  for (final list in out.values) {
    list.sort((a, b) => b.rest.length.compareTo(a.rest.length));
  }
  return out;
}

List<String> _firstVariants(String first) {
  if (_kBeForms.contains(first)) return _kBeForms.toList();
  if (_kNoVariantFirsts.contains(first)) return [first];
  final out = <String>{first};
  final irregular = _kIrregular[first];
  if (irregular != null) out.addAll(irregular);
  out.addAll(_regularForms(first));
  return out.toList();
}

List<String> _regularForms(String base) {
  final out = <String>{};
  if (base.endsWith('y') && base.length > 2) {
    final stem = base.substring(0, base.length - 1);
    out.add('${stem}ies');
    out.add('${stem}ied');
    out.add('${base}ing');
    return out.toList();
  }
  out.add('${base}s');
  if (base.endsWith('e')) {
    out.add('${base}d');
    out.add('${base.substring(0, base.length - 1)}ing');
  } else if (_kCvc(base)) {
    out.add('$base${base[base.length - 1]}ed');
    out.add('$base${base[base.length - 1]}ing');
  } else {
    out.add('${base}ed');
    out.add('${base}ing');
  }
  return out.toList();
}

bool _kCvc(String w) {
  if (w.length < 3) return false;
  final a = w[w.length - 3], b = w[w.length - 2], c = w[w.length - 1];
  const vowels = {'a', 'e', 'i', 'o', 'u'};
  const skip = {'w', 'x', 'y'};
  return !vowels.contains(a) && vowels.contains(b) && !vowels.contains(c) &&
      !skip.contains(c);
}

ClipChunkHit? _hitAt(List<_Tok> toks, int i) {
  final cands = _kIndex[toks[i].lower];
  if (cands != null) {
    for (final p in cands) {
      if (i + p.rest.length >= toks.length) continue;
      var ok = true;
      for (var j = 0; j < p.rest.length; j++) {
        if (toks[i + 1 + j].lower != p.rest[j]) {
          ok = false;
          break;
        }
      }
      if (!ok) continue;
      final text = p.canonical;
      return ClipChunkHit(
        text: text,
        key: _norm(text),
        kind: p.kind,
        start: i,
        end: i + 1 + p.rest.length,
      );
    }
  }
  // 模板：be + (really/very…) + adj + prep + 后续词
  if (_kBeForms.contains(toks[i].lower)) {
    var j = i + 1;
    if (j < toks.length && _kAdverbs.contains(toks[j].lower)) j++;
    if (j + 2 < toks.length) {
      final adj = toks[j].lower;
      final prep = toks[j + 1].lower;
      if (_kBeAdjs.contains(adj) && _kAdjPreps.contains(prep)) {
        final text = 'be $adj $prep';
        return ClipChunkHit(
          text: text,
          key: _norm(text),
          kind: '常用句型',
          start: i,
          end: j + 2,
        );
      }
    }
  }
  return null;
}
