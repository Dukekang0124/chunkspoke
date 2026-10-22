/// 系统 TTS 声音档位模型与自动优选排序。
///
/// flutter_tts 在 Android 上返回的字段全部是字符串（见插件
/// readVoiceProperties）：name / locale / quality / latency /
/// network_required("1"/"0") / features。这里只做解析与排序，
/// 不触碰平台通道，宿主单测可直接覆盖。

/// 已安装但未下载语音数据的声音会带 notInstalled 特性，选中即无声。
const String _kNotInstalled = 'notInstalled';

/// 英语变体优先级，与 TtsService 的语言回退顺序保持一致。
const List<String> kEnglishLocaleOrder = [
  'en-US',
  'en-GB',
  'en-AU',
  'en-CA',
  'en-IN',
  'en',
];

class TtsVoice {
  final String name;
  final String locale;
  final String engine;

  /// 原始档位字符串：very high / high / normal / low / very low / unknown。
  final String quality;
  final bool networkRequired;
  final String latency;
  final bool installed;

  const TtsVoice({
    required this.name,
    required this.locale,
    required this.engine,
    this.quality = 'unknown',
    this.networkRequired = false,
    this.latency = 'unknown',
    this.installed = true,
  });

  factory TtsVoice.fromMap(Map<String, String> m, {required String engine}) {
    final features = (m['features'] ?? '').toString();
    return TtsVoice(
      name: (m['name'] ?? '').toString(),
      locale: (m['locale'] ?? '').toString(),
      engine: engine,
      quality: (m['quality'] ?? 'unknown').toString(),
      networkRequired: (m['network_required'] ?? '0').toString() == '1',
      latency: (m['latency'] ?? 'unknown').toString(),
      installed: !features.split('\t').contains(_kNotInstalled),
    );
  }

  /// 质量档位（0..4）。unknown 与 very low 同为 0，避免未上报档位的声音
  /// 被误排到 low 之上。
  int get qualityRank => switch (quality) {
        'very high' => 4,
        'high' => 3,
        'normal' => 2,
        'low' => 1,
        _ => 0,
      };

  /// 延迟档位（0..4），very low 最好。
  int get latencyRank => switch (latency) {
        'very low' => 4,
        'low' => 3,
        'normal' => 2,
        'high' => 1,
        _ => 0,
      };

  bool get isEnglish =>
      kEnglishLocaleOrder.any((l) => locale == l || locale.startsWith('$l-'));

  /// en-US 优先，其次按 kEnglishLocaleOrder 逐级。
  int get localeRank {
    final i = kEnglishLocaleOrder.indexOf(locale);
    return i >= 0 ? i : kEnglishLocaleOrder.length;
  }

  /// 自动优选综合分：质量为主，network 次之，延迟再次之。
  int get autoScore => qualityRank * 2 + (networkRequired ? 1 : 0);

  /// 英文变体的口音名（仅用于 UI 明示，不参与排序）。
  String get accentLabel => switch (locale) {
        'en-US' => '美式',
        'en-GB' => '英式',
        'en-AU' => '澳式',
        'en-CA' => '加式',
        'en-IN' => '印式',
        _ => '',
      };

  /// 是否为美式英语（高清发音包音色导向用）。
  bool get isUsEnglish => locale == 'en-US';

  /// 用户可读标签（设置页展示）。
  String get label {
    final q = switch (quality) {
      'very high' => '极高',
      'high' => '高',
      'normal' => '标准',
      'low' => '低',
      _ => '未知',
    };
    final accent = accentLabel;
    final accentPart = accent.isEmpty ? '' : ' · $accent';
    return '$locale$accentPart · $q${networkRequired ? " · 联网" : " · 离线"}';
  }

  /// 持久化键：引擎|名称|locale。换引擎或语音包升级后对不上即回落自动优选。
  String get key => '$engine|$name|$locale';

  static TtsVoice? fromKey(String? key) {
    if (key == null || key.isEmpty) return null;
    final parts = key.split('|');
    if (parts.length != 3 || parts.any((e) => e.isEmpty)) return null;
    return TtsVoice(name: parts[1], locale: parts[2], engine: parts[0]);
  }
}

/// 自动优选：仅英文、仅已安装；locale → 质量/联网 → 延迟 → 引擎顺序 → 名称。
List<TtsVoice> rankTtsVoices(
  Iterable<TtsVoice> voices, {
  required List<String> engineOrder,
}) {
  final list = voices.where((v) => v.installed && v.isEnglish).toList();
  int engineIndex(TtsVoice v) {
    final i = engineOrder.indexOf(v.engine);
    return i < 0 ? engineOrder.length : i;
  }

  list.sort((a, b) {
    var c = a.localeRank.compareTo(b.localeRank);
    if (c != 0) return c;
    c = b.autoScore.compareTo(a.autoScore);
    if (c != 0) return c;
    c = b.latencyRank.compareTo(a.latencyRank);
    if (c != 0) return c;
    c = engineIndex(a).compareTo(engineIndex(b));
    if (c != 0) return c;
    return a.name.compareTo(b.name);
  });
  return list;
}
