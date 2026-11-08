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

  /// 落库序列化（D3）：档案里存的是**用户自己的文本**，`row` 不落库——
  /// 行号只属于「这份表当时怎么排的」，重排不该让块变成另一个块。
  Map<String, dynamic> toJson() => {
        'front': front,
        'back': back,
        'module_name': moduleName,
        if ((phonetic ?? '').isNotEmpty) 'phonetic': phonetic,
        if ((example ?? '').isNotEmpty) 'example': example,
        if ((cefr ?? '').isNotEmpty) 'cefr': cefr,
        if (tags.isNotEmpty) 'tags': tags,
      };

  factory UserChunkEntry.fromJson(Map<String, dynamic> j) => UserChunkEntry(
        row: 0,
        front: (j['front'] ?? '').toString(),
        back: (j['back'] ?? '').toString(),
        moduleName: (j['module_name'] ?? j['moduleName'] ?? '').toString(),
        phonetic: (j['phonetic'] ?? '').toString().isEmpty
            ? null
            : j['phonetic'].toString(),
        example:
            (j['example'] ?? '').toString().isEmpty ? null : j['example'].toString(),
        cefr: (j['cefr'] ?? '').toString().isEmpty ? null : j['cefr'].toString(),
        tags: [
          for (final t in (j['tags'] as List? ?? const [])) t.toString(),
        ],
      );
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

/// 合成场景守卫：自定义包接入六步时，PracticeLoop 的 level.id 即 moduleKey
/// （`user_module:<sha8>`）。据此把「定向替换」的替代池限定在本包内，
/// 绝不拿官方块去替换用户自己的句子（官方/收听/复习会话不受影响）。
bool isUserModuleKey(String key) => key.startsWith('user_module:');

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
    // 键名先归一到小写再查表/取值：旧写法只在 _checkKeys 里 toLowerCase，
    // 取值仍按原样 r[f]，于是 `Front` 过了字段检查却被报「front 必填缺失」。
    final norm = <String, Object?>{
      for (final e in r.entries) e.key.toString().toLowerCase(): e.value,
    };
    _checkKeys(norm.keys, i + 1, issues);
    entries.add(_entryFrom(
        row: i + 1,
        // JSON 数组值（如 tags: ['a','b']）拼成 | 分隔串交给 _entryFrom 统一切分；
        // 旧写法 .toString() 会得到 "[a, b]"，切出带方括号的脏标签。档案回读也走这里。
        get: (f) {
          final v = norm[f];
          if (v is List) return v.map((x) => x.toString()).join('|');
          return v?.toString();
        },
        issues: issues));
  }
  return _finish(entries, issues);
}

UserPackageValidation _validateCsv(String text) {
  final issues = <UserPackageIssue>[];
  final entries = <UserChunkEntry>[];
  // 保留原始行号：按行切后记下每行在文件里的真实序号（1-based），再跳过空行。
  // 旧写法 removeWhere 抹掉空行后 li+1 与用户文件对不上，中间有空行时报错指到错误的行。
  final raw = text.split(RegExp('\r\n|\r|\n'));
  final kept = <String>[];
  final rowNos = <int>[];
  for (var i = 0; i < raw.length; i++) {
    if (raw[i].trim().isEmpty) continue;
    kept.add(raw[i]);
    rowNos.add(i + 1);
  }
  if (kept.length < 2) {
    return const UserPackageValidation([], [
      UserPackageIssue(0, 'file', '只有表头，没有数据行'),
    ]);
  }
  final header = _splitCsvLine(kept.first).map((s) => s.trim().toLowerCase()).toList();
  final col = <String, int>{};
  for (var i = 0; i < header.length; i++) {
    col[header[i]] = i;
  }
  _checkKeys(header, 0, issues);
  for (final f in kUserPackageRequiredFields) {
    if (!col.containsKey(f)) issues.add(UserPackageIssue(0, f, '表头缺少必填列 $f'));
  }
  if (issues.isNotEmpty) return _finish(entries, issues);
  for (var li = 1; li < kept.length; li++) {
    final cells = _splitCsvLine(kept[li]);
    entries.add(_entryFrom(row: rowNos[li], get: (f) {
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
      issues.add(UserPackageIssue(row, f, '含控制符或不可见字符'));
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
      issues.add(UserPackageIssue(row, 'phonetic', '含控制符或不可见字符'));
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

/// 备份恢复 / 档案重建用的单条归一校验：把档案里的一条 entry JSON 过**同一套**字段闸
/// （[_entryFrom]），通过则返回 canonical 条目（trim 过、tags 切好、cefr 大写），否则 null。
///
/// 为什么必须有它：备份件是明文 JSON，谁都能手改。授权机器恢复备份时若把
/// `userpkg.*` 档案原样写回，就绕过了导入校验器（超长/脏字符/非法 cefr）与名额闸。
/// 这里与导入同源，所以手改件塞进来的脏条目会被同样挡下、如实计数。
/// [expectedModule] 非空时强制条目归属与档案声明同一模块命名空间（防跨包串名）。
UserChunkEntry? normalizeUserEntry(Map<String, dynamic> raw,
    {String? expectedModule}) {
  final norm = <String, Object?>{
    for (final e in raw.entries) e.key.toString().toLowerCase(): e.value,
  };
  final issues = <UserPackageIssue>[];
  final entry = _entryFrom(
    row: 0,
    get: (f) {
      final v = norm[f];
      if (v is List) return v.map((x) => x.toString()).join('|');
      return v?.toString();
    },
    issues: issues,
  );
  if (issues.isNotEmpty) return null;
  if (expectedModule != null &&
      entry.moduleKey != userModuleKey(expectedModule)) {
    return null;
  }
  return entry;
}

/// 字符校验走「黑名单」：只拒控制符、不可见字符、私有区与代理对，其余可见字符一律放行。
///
/// 为什么从白名单改黑名单：旧白名单只认 ASCII + U+4E00–9FA5 + IPA + 四个中文标点，
/// 把重音拉丁（café/résumé/naïve）、中日韩标点（。！？（）「」；…—）、扩展汉字与 emoji
/// 全判成「生僻符号」挡在门外——这些恰恰是用户自己词表里的正常内容（深度自查实测误拒）。
/// 安全意图不变：控制符/零宽/双向覆盖字符仍拒（它们能把渲染与判卷搅乱）。
/// 用码位判断而不是正则——raw 字符串里放引号会把字符串自己截断，这是本文件踩过的坑。
bool _allowedText(String v) {
  for (final u in v.runes) {
    if (u < 0x20) return false; // C0 控制符（含 \t\n\r，字段内不该有）
    if (u >= 0x7f && u <= 0x9f) return false; // DEL + C1
    if (u >= 0x200b && u <= 0x200f) return false; // 零宽空格/连接符/方向标记
    if (u >= 0x202a && u <= 0x202e) return false; // 双向嵌入/覆盖
    if (u >= 0x2066 && u <= 0x2069) return false; // 双向隔离
    if (u == 0xfeff) return false; // BOM / 零宽不换行
    if (u >= 0xd800 && u <= 0xdfff) return false; // 代理对（runes 已合并，正常不出现）
    if (u >= 0xe000 && u <= 0xf8ff) return false; // 私有区
    if (u >= 0xfdd0 && u <= 0xfdef) return false; // 非字符
    if (u >= 0xfff0 && u <= 0xffff) return false; // specials 区
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

/// 粘贴入口的「清单 → 模板骨架」引导转换（ASR-234）。
///
/// 用户在手机上的真实路径常常是「从别处复制一段编号清单再粘进来」，而不是先打开
/// 表格软件填好表头。真机截图实测：`1. how's it going?` … `10. Catch you later.`
/// 被当成 CSV 表头，报「未知字段」+「表头缺少必填列」——两句话都说"格式不对"，
/// 却没告诉用户"怎么改"。
///
/// 这里只做**结构转换**，不做内容创造：
///  · 去掉行首编号 / 项目符号，整行放进 `front`；
///  · `back`（释义）**留空**——路线 B 不自动翻译、不猜词义，释义必须用户自己给；
///  · `module_name` 填占位名，用户可改；
///  · 超过 [kUserPackageMaxChunks] 的行不写进骨架，如实回报 [skipped]。
///
/// 返回 null 表示「这不是一份可转换的纯清单」（JSON、CSV 表头、空内容、或大面积
/// 逗号分隔）——宁可不出按钮，也不把一份表格搅成清单。
class PlainListSuggestion {
  final String csv;
  final int lineCount;
  final int skipped;
  final String modulePlaceholder;
  const PlainListSuggestion({
    required this.csv,
    required this.lineCount,
    required this.skipped,
    required this.modulePlaceholder,
  });
}

/// 占位模块名：导入前用户可以改成自己想要的（改名后就是另一个包）。
const String kUserListModulePlaceholder = '我的词表';

PlainListSuggestion? suggestTemplateFromPlainList(String raw) {
  final text = raw.replaceFirst('\uFEFF', '').trim();
  if (text.isEmpty) return null;
  // JSON 有自己的模板，不在这里转。
  if (text.startsWith('{') || text.startsWith('[')) return null;

  final lines = <String>[];
  for (final l in text.split(RegExp('\r\n|\r|\n'))) {
    final t = l.trim();
    if (t.isNotEmpty) lines.add(t);
  }
  if (lines.isEmpty) return null;

  // 已经像 CSV 的不做清单转换，否则会把表格搅乱：
  //  · 第一行是已知表头；
  //  · 或过半的行含 ≥2 个逗号（典型的多列数据）。
  final head = lines.first.toLowerCase();
  if (head.contains('front') &&
      (head.contains('back') || head.contains('module_name'))) {
    return null;
  }
  var commaRich = 0;
  for (final l in lines) {
    if (','.allMatches(l).length >= 2) commaRich++;
  }
  if (commaRich * 2 >= lines.length) return null;

  // 行首标记：`1.` / `2)` / `3、` / `- ` / `•` 等。
  // 数字 + 句点后必须跟空白，避免把 `3.14 is pi` 削成 `14 is pi`。
  final marker =
      RegExp(r'^\s*(?:\d{1,3}\s*[\)、．]\s*|\d{1,3}\s*\.\s+|[-*]\s+|[•·–—]\s*)');
  final fronts = <String>[];
  for (final line in lines) {
    final front = _cleanFront(line.replaceFirst(marker, '').trim());
    if (front.isEmpty) continue;
    fronts.add(front);
  }
  if (fronts.isEmpty) return null;

  final kept = fronts.take(kUserPackageMaxChunks).toList();
  final rows = <String>[
    'front,back,module_name',
    for (final f in kept) '${_csvField(f)},,$kUserListModulePlaceholder',
  ];
  return PlainListSuggestion(
    csv: rows.join('\n'),
    lineCount: kept.length,
    skipped: fronts.length - kept.length,
    modulePlaceholder: kUserListModulePlaceholder,
  );
}

/// 去掉整行被引号包住的外壳（从聊天/文档复制时常见）。
String _cleanFront(String s) {
  var v = s.trim();
  if (v.length >= 2 &&
      ((v.startsWith('"') && v.endsWith('"')) ||
          (v.startsWith('“') && v.endsWith('”')) ||
          (v.startsWith("'") && v.endsWith("'")))) {
    v = v.substring(1, v.length - 1).trim();
  }
  return v;
}

/// CSV 单元格转义：含逗号/引号/换行时用双引号包住，内部引号翻倍。
String _csvField(String s) {
  if (s.contains(',') ||
      s.contains('"') ||
      s.contains('\n') ||
      s.contains('\r')) {
    return '"${s.replaceAll('"', '""')}"';
  }
  return s;
}

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
