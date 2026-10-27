/// 词块资产六态。wire 名与 App `ChunkAssetState` 的枚举名一致，
/// 顺序也与 App 枚举下标一致（落库用 index）。
enum AssetState {
  learning('learning', '新学'),
  consolidating('consolidating', '巩固中'),
  consolidated('consolidated', '已巩固'),
  longTerm('longTerm', '长期'),
  mastered('mastered', '已掌握'),
  relearning('relearning', '需重修');

  const AssetState(this.wire, this.label);

  /// 协议里唯一允许的写法。
  final String wire;

  /// 仅用于界面展示，禁止写入协议。
  final String label;

  static AssetState parse(String raw) {
    for (final s in AssetState.values) {
      if (s.wire == raw) return s;
    }
    throw FormatException(
      '非法资产状态 "$raw"：协议只接受 ${AssetState.values.map((e) => e.wire).join('|')}，'
      '中文标签（如「巩固中」）不得出现在交换文件里',
    );
  }

  static AssetState? parseOrNull(Object? raw) {
    if (raw == null) return null;
    if (raw is! String) {
      throw FormatException('非法资产状态 $raw：必须是字符串枚举名');
    }
    return parse(raw);
  }
}

/// 复习自评的协议归一命名：Web 的 1/2/3 → retry/keep/pass。
enum ReviewGrade {
  retry('retry'),
  keep('keep'),
  pass('pass');

  const ReviewGrade(this.wire);
  final String wire;

  static ReviewGrade parse(String raw) {
    for (final g in ReviewGrade.values) {
      if (g.wire == raw) return g;
    }
    throw FormatException(
      '非法 grade "$raw"：只接受 retry|keep|pass（数字 1/2/3 与中文档位不得进入协议）',
    );
  }
}
