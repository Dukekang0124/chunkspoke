/// ASR-213（1.9.0 MVP）· 用户自定义词块包：模板、解析、设备侧校验、命名空间。
///
/// 路线裁定 = B「模板化个人词块包」。**不做**自由文本自动切块（A）、不做 .apkg（C）、
/// 不做开放 API（D）、不做市场（E）；分享另立 1.9.x。
///
/// 三条结构性红线（不靠运行期校验，靠 schema 本身不存在）：
///  1. **包内没有任何媒体字段** —— 音频 100% 端侧合成，从根上杜绝大包与盗版媒体流通；
///  2. **包内没有任何 secret/key/token 字段** —— 与 codes.json / cs_build/secret 零交集；
///  3. **块 ID 一律带 `user:` 前缀** —— 与官方块表零相交，官方 167 免费口径与关卡锚点
///     不可能被用户包污染（读侧守卫见 [isUserChunkKey]）。
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';

const List<String> kUserPackageRequiredFields = ['front', 'back', 'module_name'];
const List<String> kUserPackageOptionalFields = ['phonetic', 'example', 'cefr', 'tags'];

const int kUserPackageMaxChunks = 200;
const int kUserPackageMaxPackages = 5;
const int kUserFieldMaxFront = 120;
const int kUserFieldMaxBack = 200;
const int kUserFieldMaxModule = 40;
const int kUserFieldMaxExample = 240;
const int kUserFieldMaxPhonetic = 60;
const int kUserMaxTags = 8;

const Set<String> kUserCefrLevels = {'A1', 'A2', 'B1', 'B2', 'C1', 'C2'};

/// 明确点名的禁止键（报错时给用户看得懂的原因）。
const Set<String> kUserPackageForbiddenKeys = {
  'audio', 'audiourl', 'media', 'mp3', 'wav', 'ogg', 'm4a',
  'image', 'img', 'png', 'jpg', 'jpeg', 'svg', 'file', 'path', 'url', 'uri',
  'secret', 'key', 'apikey', 'token', 'license', 'password',
};

/// 一行用户词块。
class UserChunkEntry {
  final int row;
  final String front;
  final String back;
  final String moduleName;
  final String? phonetic;
  final String? example;
  final String? cefr;
  final List<String> tags;

  const UserChunkEntry({
    required this.row,
    required this.front,
    required this.back,
    required this.moduleName,
    this.phonetic,
    this.example,
    this.cefr,
    this.tags = const [],
  });

  /// 块 ID：`user:<sha8>`。同一内容在任何设备上得到同一 ID，重复导入可幂等替换自己的包。
  String get chunkKey => 'user:${sha8Of(front)}';

  /// 模块 ID：`user_module:<sha8>`。
  String get moduleKey => userModuleKey(moduleName);

  /// 依赖整句的那几步用哪句话；没有就返回 null，由 UI 说明「这一步为什么跳过」。
  String? get sentenceSourceText {
    final e = (example ?? '').trim();
    if (e.split(' ').length >= 3) return e;
    final f = front.trim();
    return f.split(' ').length >= 3 ? f : null;
  }

  /// 六步可用位：拆解/影子跟读/定向替换都要整句，只有 example（或 front 本身是句子）时才可跑。
  bool get hasSentenceForSpeakingSteps => sentenceSourceText != null;
}

/// 行级报错：第几行、哪个字段、什么问题。
class UserPackageIssue {
  final int row; // 0 = 整包级
  final String field;
  final String reason;
  const UserPackageIssue(this.row, this.field, this.reason);
  @override
  String toString() => row == 0 ? '[$field] $reason' : '第 $row 行 · $field：$reason';
}

class UserPackageValidation {
  final List<UserChunkEntry> entries;
  final List<UserPackageIssue> issues;
  const UserPackageValidation(this.entries, this.issues);
  bool get ok => issues.isEmpty;
  int get packageCount => entries.map((e) => e.moduleKey).toSet().length;
  String get firstErrorText => issues.isEmpty ? '' : issues.first.toString();
}

/// 命名空间守卫：官方读点（词块库/复习/磨耳朵/免费 167 口径/关卡锚点）一律不得聚合 user 键。
bool isUserChunkKey(String key) => key.startsWith('user:');

String userModuleKey(String moduleName) =>
    'user_module:${sha8Of(moduleName.trim().toLowerCase())}';

/// 内容寻址短哈希：sha256 前 8 位十六进制。
String sha8Of(String s) => sha256.convert(utf8.encode(s)).toString().substring(0, 8);

/// 自动判别格式并解析校验。CSV 与 JSON 二选一，不做通用转换器。
UserPackageValidation parseAndValidateUserPackage(String raw) {
  final text = raw.replaceFirst('\uFEFF', '').trim();
  if (text.isEmpty) {
    return const UserPackageValidation([], [
      UserPackageIssue(0, 'file', '内容为空，先用「下载模板」拿到表头再填'),
    ]);
  }
  if (text.startsWith('{') || text.startsWith('[')) return _validateJson(text);
  return _validateCsv(text);
}

UserPackageValidation _validateJson(String text) {
  final issues = <UserPackageIssue>[];
  final entries = <UserChunkEntry>[];
  Object? decoded;
  try {
    decoded = jsonDecode(text);
  } catch (_) {
    return const UserPackageValidation([], [
      UserPackageIssue(0, 'file', 'JSON 解析失败，检查引号与逗号'),
    ]);
  }
  final rows = decoded is List
      ? decoded
      : (decoded is Map && decoded['chunks'] is List)
          ? decoded['chunks'] as List
          : null;
  if (rows == null) {
    return const UserPackageValidation([], [
      UserPackageIssue(0, 'file', 'JSON 顶层要是数组，或含 chunks 数组的对象'),
    ]);
  }
  for (var i = 0; i < rows.length; i++) {
    final r = rows[i];
    if (r is! Map) {
      issues.add(UserPackageIssue(i + 1, 'row', '这一项不是对象'));
      continue;
    }
    _checkKeys(r.keys.map((k) => k.toString().toLowerCase()), i + 1, issues);
    entries.add(_entryFrom(row: i + 1, get: (f) => r[f]?.toString(), issues: issues));
  }
  return _finish(entries, issues);
}

UserPackageValidation _validateCsv(String text) {
  final issues = <UserPackageIssue>[];
  final entries = <UserChunkEntry>[];
  final lines = text.split(RegExp('\r\n|\r|\n'))
    ..removeWhere((l) => l.trim().isEmpty);
  if (lines.length < 2) {
    return const UserPackageValidation([], [
      UserPackageIssue(0, 'file', '只有表头，没有数据行'),
    ]);
  }
  final header = _splitCsvLine(lines.first).map((s) => s.trim().toLowerCase()).toList();
  final col = <String, int>{};
  for (var i = 0; i < header.length; i++) {
    col[header[i]] = i;
  }
  _checkKeys(header, 0, issues);
  for (final f in kUserPackageRequiredFields) {
    if (!col.containsKey(f)) issues.add(UserPackageIssue(0, f, '表头缺少必填列 $f'));
  }
  if (issues.isNotEmpty) return _finish(entries, issues);
  for (var li = 1; li < lines.length; li++) {
    final cells = _splitCsvLine(lines[li]);
    entries.add(_entryFrom(row: li + 1, get: (f) {
      final idx = col[f];
      if (idx == null || idx >= cells.length) return null;
      return cells[idx].trim();
    }, issues: issues));
  }
  return _finish(entries, issues);
}

UserChunkEntry _entryFrom({
  required int row,
  required String? Function(String field) get,
  required List<UserPackageIssue> issues,
}) {
  String need(String f, int max) {
    final v = (get(f) ?? '').trim();
    if (v.isEmpty) {
      issues.add(UserPackageIssue(row, f, '必填，不能为空'));
    } else if (v.length > max) {
      issues.add(UserPackageIssue(row, f, '超过 $max 字（当前 ${v.length}）'));
    } else if (!_allowedText(v)) {
      issues.add(UserPackageIssue(row, f, '含不允许的字符（控制符/生僻符号）'));
    }
    return v;
  }

  final front = need('front', kUserFieldMaxFront);
  final back = need('back', kUserFieldMaxBack);
  final module = need('module_name', kUserFieldMaxModule);

  final phonetic = (get('phonetic') ?? '').trim();
  if (phonetic.isNotEmpty) {
    if (phonetic.length > kUserFieldMaxPhonetic) {
      issues.add(UserPackageIssue(row, 'phonetic', '超过 $kUserFieldMaxPhonetic 字'));
    } else if (!_allowedText(phonetic)) {
      issues.add(UserPackageIssue(row, 'phonetic', '只接受 IPA 扩展区与 ASCII 符号'));
    }
  }

  final example = (get('example') ?? '').trim();
  if (example.isNotEmpty && example.length > kUserFieldMaxExample) {
    issues.add(UserPackageIssue(row, 'example', '超过 $kUserFieldMaxExample 字'));
  }

  final cefr = (get('cefr') ?? '').trim().toUpperCase();
  if (cefr.isNotEmpty && !kUserCefrLevels.contains(cefr)) {
    issues.add(UserPackageIssue(row, 'cefr', '只能是 A1/A2/B1/B2/C1/C2（当前 $cefr）'));
  }

  final tags = (get('tags') ?? '')
      .split(RegExp('[,;|]'))
      .map((t) => t.trim())
      .where((t) => t.isNotEmpty)
      .toList();
  if (tags.length > kUserMaxTags) {
    issues.add(UserPackageIssue(row, 'tags', '最多 $kUserMaxTags 个标签'));
    tags.removeRange(kUserMaxTags, tags.length);
  }

  return UserChunkEntry(
    row: row,
    front: front,
    back: back,
    moduleName: module,
    phonetic: phonetic.isEmpty ? null : phonetic,
    example: example.isEmpty ? null : example,
    cefr: cefr.isEmpty ? null : cefr,
    tags: tags,
  );
}

/// 字符白名单：可见 ASCII、汉字、IPA 扩展与组合音标、少量中文标点。
/// 用码位判断而不是正则——raw 字符串里放引号会把字符串自己截断，这是本文件踩过的坑。
bool _allowedText(String v) {
  for (final u in v.runes) {
    if (u >= 0x20 && u <= 0x7e) continue;
    if (u >= 0x4e00 && u <= 0x9fa5) continue;
    if (u >= 0x250 && u <= 0x2ff) continue;
    if (u >= 0x300 && u <= 0x36f) continue;
    if (u == 0x2018 || u == 0x2019 || u == 0x201c || u == 0x201d) continue;
    if (u == 0xff0c || u == 0x3001 || u == 0xff1a || u == 0xb7) continue;
    return false;
  }
  return true;
}

void _checkKeys(Iterable<String> keys, int row, List<UserPackageIssue> issues) {
  final allowed = {...kUserPackageRequiredFields, ...kUserPackageOptionalFields};
  for (final k in keys) {
    if (allowed.contains(k)) continue;
    if (kUserPackageForbiddenKeys.contains(k.replaceAll('_', ''))) {
      issues.add(UserPackageIssue(
          row, k, '本格式不允许该字段：音频由本机合成，密钥类字段一律禁止'));
    } else {
      issues.add(UserPackageIssue(row, k, '未知字段，只认 ${allowed.join('/')}'));
    }
  }
}

UserPackageValidation _finish(List<UserChunkEntry> entries, List<UserPackageIssue> issues) {
  final seen = <String, int>{};
  for (final e in entries) {
    if (e.front.isEmpty || e.back.isEmpty || e.moduleName.isEmpty) continue;
    final dup = seen[e.chunkKey];
    if (dup != null) {
      issues.add(UserPackageIssue(e.row, 'front', '与第 $dup 行内容重复'));
    } else {
      seen[e.chunkKey] = e.row;
    }
  }
  if (entries.length > kUserPackageMaxChunks) {
    issues.add(UserPackageIssue(0, 'file',
        '超出每包 $kUserPackageMaxChunks 块上限（当前 ${entries.length}）'));
  }
  return UserPackageValidation(entries, issues);
}

/// 模板（一键下载用）。CSV 与 JSON 各一份，字段与校验器同源——模板自身必须过闸，
/// 这条断言在 test/user_package_test.dart：改了字段表不同步改模板会直接红。
String userPackageCsvTemplate() => [
      'front,back,module_name,phonetic,example,cefr,tags',
      "\"I'd like a window seat.\",我想要靠窗的座位,航空出行,"
      "'aɪd lak ə ˈwndəʊ st,\"Excuse me, I'd like a window seat.\",B1,check-in|seat",
      'plate,盘子,餐饮点餐,,The main course was great.,A2,tableware',
    ].join('\n');

String userPackageJsonTemplate() => jsonEncode([
      {
        'front': "I'd like a window seat.",
        'back': '我想要靠窗的座位',
        'module_name': '航空出行',
        'phonetic': "'aɪd laɪk ə ˈwɪndə sɪt",
        'example': "Excuse me, I'd like a window seat.",
        'cefr': 'B1',
        'tags': 'check-in,seat',
      },
      {
        'front': 'plate',
        'back': '盘子，餐具',
        'module_name': '餐饮点餐',
        'example': 'The main course was great.',
        'cefr': 'A2',
        'tags': 'tableware',
      },
    ]);

List<String> _splitCsvLine(String line) {
  final out = <String>[];
  final sb = StringBuffer();
  var quoted = false;
  for (var i = 0; i < line.length; i++) {
    final c = line[i];
    if (quoted) {
      if (c == '"') {
        if (i + 1 < line.length && line[i + 1] == '"') {
          sb.write('"');
          i++;
        } else {
          quoted = false;
        }
      } else {
        sb.write(c);
      }
    } else if (c == '"') {
      quoted = true;
    } else if (c == ',') {
      out.add(sb.toString());
      sb.clear();
    } else {
      sb.write(c);
    }
  }
  out.add(sb.toString());
  return out;
}
