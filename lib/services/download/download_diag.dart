import 'dart:io';

/// 一条下载尝试的记录。全部字段都是「本机已经知道的事实」，不含任何用户内容，
/// 也不会上传：只在失败页由用户自己点「复制诊断信息」拿去贴给开发者。
class DiagEntry {
  /// 阶段：清单 / 分块 / 整包 / 续传 / 校验。
  final String phase;

  /// 该次尝试使用的地址（尽量保留，便于判断是哪个源挂了）。
  final String source;

  /// HTTP 状态码；0 表示没有拿到响应（连接失败/超时/被重置）。
  final int http;

  /// 该阶段期望的总字节数（0 = 未知）。
  final int expected;

  /// 实际落到本地或实际收到的字节数。
  final int actual;

  /// 校验时算出的 sha256 前缀（8 位），未校验时为空。
  final String shaPrefix;

  /// 人读备注（如「长度不足」「sha 不符」「服务器忽略 Range」）。
  final String note;

  const DiagEntry({
    required this.phase,
    required this.source,
    this.http = 0,
    this.expected = 0,
    this.actual = 0,
    this.shaPrefix = '',
    this.note = '',
  });
}

/// 一次下载任务的诊断上下文：按顺序累积每次尝试，失败时整段交给用户复制。
///
/// 红线：只读本机状态（HTTP 码、字节数、本机网络接口名），不发送、不落盘埋点。
class DownloadDiag {
  DownloadDiag({
    required this.task,
    this.expectedBytes = 0,
    this.sha256 = '',
  });

  /// 任务名，如「安装包 chunkspoke_update.apk」「语音模型 vosk-model-small-en-us-0.15」。
  final String task;
  final int expectedBytes;
  final String sha256;
  final DateTime startedAt = DateTime.now();
  final List<DiagEntry> entries = <DiagEntry>[];

  bool get isEmpty => entries.isEmpty;

  DiagEntry add({
    required String phase,
    required String source,
    int http = 0,
    int expected = 0,
    int actual = 0,
    String shaPrefix = '',
    String note = '',
  }) {
    final e = DiagEntry(
      phase: phase,
      source: source,
      http: http,
      expected: expected,
      actual: actual,
      shaPrefix: shaPrefix,
      note: note,
    );
    entries.add(e);
    return e;
  }

  /// 渲染成可直接粘贴的一段文本。[net] / [app] / [abi] 由调用方补齐（异步取值的地方在 UI 层）。
  String render({
    String app = '',
    String net = '',
    String abi = '',
    String? conclusion,
  }) {
    final b = StringBuffer();
    b.writeln('ChunkSpoke 下载诊断');
    if (app.isNotEmpty) b.writeln('版本 $app${abi.isEmpty ? '' : ' / $abi'}');
    b.writeln('时间 ${_stamp(startedAt)}');
    if (net.isNotEmpty) b.writeln('网络 $net');
    b.writeln('任务 $task'
        '${expectedBytes > 0 ? '  目标 ${_bytes(expectedBytes)}' : ''}'
        '${sha256.isEmpty ? '' : '  期望sha ${_sha(sha256)}'}');
    for (var i = 0; i < entries.length; i++) {
      final e = entries[i];
      final code = e.http == 0 ? '无响应' : 'HTTP ${e.http}';
      final size = e.expected > 0 || e.actual > 0
          ? '  ${_bytes(e.actual)}${e.expected > 0 ? '/${_bytes(e.expected)}' : ''}'
          : '';
      final sha = e.shaPrefix.isEmpty ? '' : '  sha=${e.shaPrefix}';
      final note = e.note.isEmpty ? '' : '  ${e.note}';
      b.writeln('${i + 1}. [${e.phase}] ${e.source}  $code$size$sha$note');
    }
    b.writeln('结论 ${conclusion ?? '全部源失败（共 ${entries.length} 次尝试）'}');
    return b.toString().trimRight();
  }

  static String _bytes(int n) {
    if (n >= 1024 * 1024) return '${(n / 1024 / 1024).toStringAsFixed(1)}MB';
    if (n >= 1024) return '${(n / 1024).toStringAsFixed(0)}KB';
    return '${n}B';
  }

  static String _sha(String s) =>
      s.length >= 8 ? '${s.substring(0, 8)}…' : s;

  static String _stamp(DateTime t) {
    String two(int v) => v.toString().padLeft(2, '0');
    final off = t.timeZoneOffset;
    final sign = off.isNegative ? '-' : '+';
    final h = off.inHours.abs();
    final m = off.inMinutes.abs() % 60;
    return '${t.year}-${two(t.month)}-${two(t.day)} '
        '${two(t.hour)}:${two(t.minute)}:${two(t.second)} '
        '$sign${two(h)}:${two(m)}';
  }
}

/// 本机网络类型（读网络接口名，不发任何请求）。
/// 无法判定时返回「未知」，绝不阻塞下载。
Future<String> networkLabel() async {
  try {
    final list = await NetworkInterface.list(includeLoopback: false, type: InternetAddressType.IPv4);
    if (list.isEmpty) list.addAll(await NetworkInterface.list(includeLoopback: false));
    if (list.isEmpty) return '无网络接口';
    final names = list.map((e) => e.name.toLowerCase()).toList();
    final wifi = names.any((n) =>
        n.startsWith('wlan') || n.startsWith('eth') || n.startsWith('ap') || n.startsWith('en'));
    final cell = names.any((n) =>
        n.startsWith('rmnet') || n.startsWith('ccmni') || n.startsWith('seth') || n.contains('cellular'));
    if (wifi && cell) return 'WiFi+移动数据（接口 ${names.join(',')}）';
    if (wifi) return 'WiFi（接口 ${names.first}）';
    if (cell) return '移动数据（接口 ${names.first}）';
    return '其它（接口 ${names.join(',')}）';
  } catch (_) {
    return '未知';
  }
}
