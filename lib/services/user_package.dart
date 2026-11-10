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

/// 必填只有「英文」和「词表名」。
///
/// 中文意思（back）自 1.9.2 起**可选**：用户粘一段英文进来就是为了学，
/// 不该先被逼着翻译一遍才能保存。空释义在六步里降级为「不显示翻译行」，
/// 校验闸（长度/不可见字符/CEFR）对非空的释义照旧生效。
const List<String> kUserPackageRequiredFields = ['front', 'module_name'];
const List<String> kUserPackageOptionalFields = [
  'back',
  'phonetic',
  'example',
  'cefr',
  'tags',
];

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
      UserPackageIssue(0, 'file', '还没有内容，先把想学的英文粘进来'),
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
  final module = need('module_name', kUserFieldMaxModule);

  // 释义可选：空着就空着，有内容才过长/字符闸。
  final back = (get('back') ?? '').trim();
  if (back.isNotEmpty) {
    if (back.length > kUserFieldMaxBack) {
      issues.add(UserPackageIssue(row, 'back', '超过 $kUserFieldMaxBack 字（当前 ${back.length}）'));
    } else if (!_allowedText(back)) {
      issues.add(UserPackageIssue(row, 'back', '含控制符或不可见字符'));
    }
  }

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
    if (e.front.isEmpty || e.moduleName.isEmpty) continue;
    final dup = seen[e.chunkKey];
    if (dup != null) {
      issues.add(UserPackageIssue(e.row, 'front', '与第 $dup 行内容重复'));
    } else {
      seen[e.chunkKey] = e.row;
    }
  }
  if (entries.length > kUserPackageMaxChunks) {
    issues.add(UserPackageIssue(0, 'file',
        '超出每本 $kUserPackageMaxChunks 句（现在有 ${entries.length} 句）'));
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

/// 用户没给词表起名时的默认名。
///
/// 叫「英语本」而不是「模块/包」：这一份东西在用户眼里就是自己的一个本子。
/// 表里的 `module_name` 仍是存储口径，只换展示词。
const String kUserDefaultModuleName = '我的英语本';

/// 旧的占位名保留导出（1.9.1 的测试/调用可能还在用），值跟默认名同步。
const String kUserListModulePlaceholder = kUserDefaultModuleName;

/// 行级问题翻成学习者看得懂的人话（只用于展示，不改校验口径）。
///
/// 用模式匹配而不是「复制一份 reason 字符串表」：校验器的原话仍留在
/// [UserPackageIssue] 里，展示层只负责加人称、去黑话；两条入口（粘贴/表格）
/// 共用这一处，避免同一句错误在页面上出现两种说法。
String describeIssueForLearner(UserPackageIssue issue) {
  final field = switch (issue.field) {
    'front' => '英文',
    'back' => '中文意思',
    'module_name' => '本子的名字',
    'phonetic' => '音标',
    'example' => '例句',
    'cefr' => '难度',
    'tags' => '标签',
    'file' => '内容',
    'row' => '这一行',
    _ => issue.field,
  };
  final raw = issue.reason;
  // 整包级问题：不加「英文：」这种前缀，直接说人话。
  if (issue.row == 0) {
    if (raw.startsWith('表头缺少必填列')) {
      return '第一行的标题少了「English / 英文」这一列。直接粘贴文字就不用管标题行。';
    }
    if (raw.startsWith('未知字段')) {
      return '有一列我不认识。可以直接粘贴文字，我帮你整理。';
    }
    if (raw.startsWith('JSON')) {
      return '这份文件格式有点乱，多半少了逗号或引号。也可以直接粘贴文字让我整理。';
    }
    if (raw.startsWith('只有表头')) return '只有第一行标题，下面还没有内容。';
    if (raw.startsWith('超出每本')) return raw;
    if (raw.startsWith('内容为空')) return '还没有内容。';
    if (raw.startsWith('没认出') || raw.startsWith('先把')) return raw;
    return raw;
  }
  // 英文超长：不报 CSV 行号（粘贴用户看不懂「第 2 行」），直接教怎么改。
  if (issue.field == 'front' && raw.startsWith('超过')) {
    return '有句英文太长了，一次学不下。在中间加个句号分成两句，再点「整理成句子」就好。';
  }
  final reason = switch (raw) {
    '必填，不能为空' => '还是空的，补上就能继续',
    '含控制符或不可见字符' => '里有看不见的字符，删掉重新打一遍',
    '这一项不是对象' => '这一行格式不对',
    _ when raw.startsWith('与第') && raw.endsWith('内容重复') => '和前面那句重复了，删掉一句',
    _ when raw.startsWith('超过') => raw,
    _ when raw.startsWith('只能是 A1') => '难度只填 A1–C2 里的一个，或者留空',
    _ when raw.startsWith('最多') => raw,
    _ => raw,
  };
  return '第 ${issue.row} 行 · $field：$reason';
}

/// CSV 单元格转义：含逗号/引号/换行时用双引号包住，内部引号翻倍。
///
/// 公开给「粘贴文本 → 词块」的解析器复用：它把识别结果拼成 CSV 再走同一套闸，
/// 保证两条入口（粘贴/表格）的字段限制与字符校验完全同源。
String csvField(String s) {
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
