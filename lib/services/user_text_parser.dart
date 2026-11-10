/// 1.9.2 · 「把想学的英文直接粘进来」的结构识别器。
///
/// 这不是翻译器，也不是 AI 改写器。它只做**结构**三件事：
///  1. 认出这是对话（`A: …`）、中英对照（`Hello | 你好` 或英文下一行中文）、
///     一整段英文，还是一份清单；
///  2. 按行/句切开，去掉编号、项目符号、外层的引号和说话人；
///  3. 把结果拼成一份 CSV，交给 [parseAndValidateUserPackage] 过**同一套**闸
///     （长度、不可见字符、CEFR、重复、每包 200 条），绝不另起一套校验。
///
/// 红线：**不自动翻译、不猜词义**。英文行没有配中文时，释义就留空——
/// 空释义在六步里只是不显示翻译行，不会挡住学习。
library;

import 'user_package.dart';

/// 粘贴文本整理后的结果。
class PastedTextPlan {
  /// 已过同一套校验闸的条目（`back` 可能为空）。
  final UserPackageValidation validation;

  /// 给用户看的一句话归类，例如「一段对话」「中英对照」。
  final String kindLabel;

  /// 本次采用的词表名。
  final String moduleName;

  /// 从文本里直接读到的中文释义条数（不是翻译出来的）。
  final int pairedCount;

  /// 没配中文释义的条数。
  final int meaningMissing;

  /// 超出一包 200 条、没有放进来的条数。
  final int skipped;

  /// 没有英文、被略过的行数。
  final int droppedNonEnglish;

  /// 重复、被合并掉的条数。
  final int duplicates;

  /// 展示用的补充说明（已排好顺序，全是人话）。
  final List<String> notes;

  const PastedTextPlan({
    required this.validation,
    required this.kindLabel,
    required this.moduleName,
    required this.pairedCount,
    required this.meaningMissing,
    required this.skipped,
    required this.droppedNonEnglish,
    required this.duplicates,
    required this.notes,
  });

  bool get ok => validation.ok;
  List<UserChunkEntry> get entries => validation.entries;
}

final RegExp _cjk = RegExp(r'[\u4e00-\u9fff]');
final RegExp _latin = RegExp(r'[A-Za-z]');
final RegExp _lineBreak = RegExp(r'\r\n|\r|\n');

/// 行首编号 / 项目符号：`1.` / `2)` / `3、` / `- ` / `•` 等，
/// 以及字幕/转录的时间戳 `00:12 ` / `01:30:45 `（粘视频台词常见）。
/// 数字 + 句点后必须跟空白，避免把 `3.14 is pi` 削成 `14 is pi`。
final RegExp _marker = RegExp(
    r'^\s*(?:\d{1,3}\s*[\)、．]\s*|\d{1,3}\s*\.\s+|[-*]\s+|[•·–—]\s*|\d{1,2}:\d{2}(?::\d{2})?\s+)');

/// 对话说话人：`A:` / `Tom:` / `小明：`。只认 20 字符以内的短标签。
/// `http://` 这类会被排除，不把网址当说话人。
final RegExp _speaker = RegExp(
    r"^([A-Za-z][A-Za-z .’'-]{0,19}|[\u4e00-\u9fff]{1,6})\s*[:：]\s*(.+)$");

/// 常见缩写：句点不算句末。
const Set<String> _abbr = {
  'mr', 'mrs', 'ms', 'dr', 'prof', 'st', 'vs', 'etc', 'eg', 'ie',
  'am', 'pm', 'no', 'jr', 'sr',
};

/// 显式分隔的「英文 + 中文」对照，例如 `Hello | 你好`、`Hello<TAB>你好`。
const List<String> _pairSeparators = ['\t', ' | ', '|', '｜', ' → ', '→', '=>', ' = ', ' – ', ' — '];

/// 把粘贴文本整理成词块。返回 null 表示「这是一份表格/JSON」，
/// 调用方应改用 [parseAndValidateUserPackage] 的表格入口，而不是强行切句。
PastedTextPlan? parsePastedUserText(String raw, {String? moduleName}) {
  final text = raw.replaceFirst('\uFEFF', '').trim();
  final name = (moduleName ?? '').trim().isEmpty
      ? kUserDefaultModuleName
      : moduleName!.trim();

  if (text.isEmpty) {
    return PastedTextPlan(
      validation: const UserPackageValidation([], [
        UserPackageIssue(0, 'file', '先把想学的英文粘贴进来'),
      ]),
      kindLabel: '还没有内容',
      moduleName: name,
      pairedCount: 0,
      meaningMissing: 0,
      skipped: 0,
      droppedNonEnglish: 0,
      duplicates: 0,
      notes: const ['一句话、一段话、一段对话都可以，直接粘在上面的框里。'],
    );
  }

  // 表格 / JSON 走原来的入口，不在这里搅乱。
  if (_looksLikeTable(text)) return null;

  final rawLines = [
    for (final l in text.split(_lineBreak))
      if (l.trim().isNotEmpty) l.trim(),
  ];

  final items = <_PasteItem>[];
  var dialogueLines = 0;
  var dropped = 0;
  var i = 0;
  while (i < rawLines.length) {
    final line = rawLines[i].replaceFirst(_marker, '').trim();
    if (line.isEmpty) {
      i++;
      continue;
    }

    // ① 显式中英对照（制表符 / 竖线 / 箭头）。
    final pair = _explicitPair(line);
    if (pair != null) {
      items.add(_PasteItem(front: _clean(pair.$1), back: _clean(pair.$2)));
      i++;
      continue;
    }

    // ② 去掉说话人，并记下这是对话。
    var body = line;
    final speaker = _speaker.firstMatch(line);
    if (speaker != null) {
      final label = speaker.group(1)!.trim().toLowerCase();
      final rest = speaker.group(2)!.trim();
      // `Visit https://…` 不是对话：冒号后面跟 `//` 是网址，别把前半句吃掉。
      if (label != 'http' &&
          label != 'https' &&
          !rest.startsWith('//') &&
          _latin.hasMatch(rest)) {
        body = rest;
        dialogueLines++;
      }
    }

    // ③ 纯中文行：只可能是上一句的释义（已在上一轮吃掉）或无关备注，跳过。
    if (!_latin.hasMatch(body)) {
      dropped++;
      i++;
      continue;
    }

    // ④ 下一行是纯中文 → 结构上的「英文 + 中文」对照，直接当释义。
    var back = '';
    if (i + 1 < rawLines.length) {
      final next = rawLines[i + 1].replaceFirst(_marker, '').trim();
      if (next.isNotEmpty &&
          !_latin.hasMatch(next) &&
          _cjk.hasMatch(next) &&
          _explicitPair(next) == null) {
        back = _clean(next);
        i++;
      }
    }

    final front = _clean(body);
    if (front.isEmpty) {
      i++;
      continue;
    }

    // ⑤ 有释义的整行不拆；没有释义的一整段按句切开，一句一块。
    if (back.isNotEmpty) {
      items.add(_PasteItem(front: front, back: back));
    } else {
      for (final s in splitEnglishSentences(front)) {
        items.add(_PasteItem(front: s, back: ''));
      }
    }
    i++;
  }

  // 去重（不分大小写）+ 200 条上限，如实计数。
  final seen = <String>{};
  final kept = <_PasteItem>[];
  var duplicates = 0;
  var skipped = 0;
  for (final it in items) {
    final key = it.front.trim().toLowerCase();
    if (!seen.add(key)) {
      duplicates++;
      continue;
    }
    if (kept.length >= kUserPackageMaxChunks) {
      skipped++;
      continue;
    }
    kept.add(it);
  }

  if (kept.isEmpty) {
    return PastedTextPlan(
      validation: const UserPackageValidation([], [
        UserPackageIssue(0, 'file',
            '没认出英文内容：把想学的英文一行一句粘进来，或按句子分段再试'),
      ]),
      kindLabel: '没认出英文内容',
      moduleName: name,
      pairedCount: 0,
      meaningMissing: 0,
      skipped: 0,
      droppedNonEnglish: dropped,
      duplicates: duplicates,
      notes: [
        if (dropped > 0) '有 $dropped 行没有英文，已经跳过。',
      ],
    );
  }

  // 复用表格入口的同一套字段闸：拼 CSV 再过 parseAndValidateUserPackage。
  final rows = <String>['front,back,module_name'];
  for (final it in kept) {
    rows.add(
        '${csvField(it.front)},${csvField(it.back)},${csvField(name)}');
  }
  final validation = parseAndValidateUserPackage(rows.join('\n'));

  final paired = kept.where((e) => e.back.trim().isNotEmpty).length;
  final missing = kept.length - paired;
  final sentenceCount = kept.fold<int>(0, (n, e) => n + splitEnglishSentences(e.front).length);

  final kind = dialogueLines > 0
      ? (paired > 0 ? '中英对照的对话' : '一段对话')
      : paired > 0
          ? '中英对照'
          : rawLines.length > 1 || sentenceCount > 1
              ? '一段英文'
              : '一句英文';

  final notes = <String>[
    '认出了 $kind，整理成 ${kept.length} 句。',
    if (paired > 0) '其中 $paired 句自带中文，已经放到释义里。',
    if (missing > 0) '还有 $missing 句没有中文意思，不影响练习，只是练的时候不显示翻译。',
    if (duplicates > 0) '有 $duplicates 句重复，已经合并。',
    if (skipped > 0) '一次最多 $kUserPackageMaxChunks 句，后面 $skipped 句没有放进来。',
    if (dropped > 0) '有 $dropped 行没有英文，已经跳过。',
  ];

  return PastedTextPlan(
    validation: validation,
    kindLabel: kind,
    moduleName: name,
    pairedCount: paired,
    meaningMissing: missing,
    skipped: skipped,
    droppedNonEnglish: dropped,
    duplicates: duplicates,
    notes: notes,
  );
}

class _PasteItem {
  final String front;
  final String back;
  const _PasteItem({required this.front, required this.back});
}

/// 表格 / JSON 的保守识别：
///  · 以 `{`/`[` 开头；
///  · 第一行是 `front,back,module_name` 这类已知表头；
///  · 连续几行的逗号数量稳定且 ≥2（多列表格的典型形状，正常对话很少这样）。
bool _looksLikeTable(String text) {
  final t = text.trimLeft();
  if (t.startsWith('{') || t.startsWith('[')) return true;
  final lines = [
    for (final l in t.split(_lineBreak))
      if (l.trim().isNotEmpty) l.trim(),
  ];
  if (lines.isEmpty) return false;
  final head = lines.first.toLowerCase();
  if (head.contains('front') &&
      (head.contains('back') || head.contains('module_name'))) {
    return true;
  }
  final probe = lines.take(3).toList();
  if (probe.length < 2) return false;
  // 散文信号：句末标点（. ! ? …）或「逗号+空格」。普通英文句子几乎必占其一，
  // 而真正的无表头表格（a,b,c）两者都没有。不加这一闸，带逗号的散文会被
  // 误判成表格，给用户甩一堆「未知字段/表头缺少必填列」的黑话。
  final proseSignal = RegExp(r'[.!?…]|,\s');
  if (probe.any((l) => proseSignal.hasMatch(l))) return false;
  final counts = [for (final l in probe) ','.allMatches(l).length];
  return counts.every((c) => c >= 2) && counts.toSet().length <= 2;
}

/// 显式「英文 + 中文」对照：分隔符两侧必须一边有英文、一边有中文。
(String, String)? _explicitPair(String line) {
  for (final sep in _pairSeparators) {
    final at = line.indexOf(sep);
    if (at <= 0) continue;
    final left = line.substring(0, at).trim();
    final right = line.substring(at + sep.length).trim();
    if (left.isEmpty || right.isEmpty) continue;
    if (_latin.hasMatch(left) && _cjk.hasMatch(right)) return (left, right);
  }
  return null;
}

/// 去掉整行被引号包住的外壳（从聊天/文档复制时常见）。
String _clean(String s) {
  var v = s.trim();
  if (v.length >= 2 &&
      ((v.startsWith('"') && v.endsWith('"')) ||
          (v.startsWith('“') && v.endsWith('”')) ||
          (v.startsWith("'") && v.endsWith("'")))) {
    v = v.substring(1, v.length - 1).trim();
  }
  return v;
}

/// 英文按句切开。缩写（Mr. / e.g.）和 U.S. 这类字母点缩写不算句末。
List<String> splitEnglishSentences(String text) {
  final t = text.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (t.isEmpty) return const [];
  final out = <String>[];
  var start = 0;
  String? lastPiece;
  for (var i = 0; i < t.length; i++) {
    final c = t[i];
    if (c != '.' && c != '!' && c != '?' && c != '…') continue;

    var end = i + 1;
    while (end < t.length &&
        (t[end] == '.' || t[end] == '!' || t[end] == '?' || t[end] == '…')) {
      end++;
    }
    // 句末后紧跟的引号/括号归到这一句。
    while (end < t.length &&
        (t[end] == '"' ||
            t[end] == "'" ||
            t[end] == '”' ||
            t[end] == '’' ||
            t[end] == ')' ||
            t[end] == '）')) {
      end++;
    }
    // 句点后不是空格：小数、网址、缩写内部，不切。
    if (end < t.length && t[end] != ' ') {
      i = end - 1;
      continue;
    }
    // 字母点缩写（U.S）不切。
    if (c == '.' &&
        i > 0 &&
        i + 1 < t.length &&
        _isUpperAscii(t[i - 1]) &&
        _isUpperAscii(t[i + 1])) {
      i = end - 1;
      continue;
    }
    // 常见缩写不切。
    if (c == '.') {
      final before = t.substring(start, i).trimRight();
      final words = before.split(RegExp(r'\s+'));
      final last = words.isEmpty
          ? ''
          : words.last.toLowerCase().replaceAll(RegExp(r'[^a-zё]'), '');
      if (_abbr.contains(last)) {
        i = end - 1;
        continue;
      }
    }
    final piece = t.substring(start, end).trim();
    // 纯表情/纯标点/纯数字的碎片（如句尾甩出的 `🎉`）不是能学的英文，不收。
    if (piece.isNotEmpty && piece != lastPiece && _latin.hasMatch(piece)) {
      out.add(piece);
      lastPiece = piece;
    }
    while (end < t.length && t[end] == ' ') {
      end++;
    }
    start = end;
    i = end - 1;
  }
  final tail = t.substring(start).trim();
  if (tail.isNotEmpty && tail != lastPiece && _latin.hasMatch(tail)) out.add(tail);
  return out.isEmpty ? [t] : out;
}

bool _isUpperAscii(String ch) {
  final u = ch.codeUnitAt(0);
  return u >= 65 && u <= 90;
}
