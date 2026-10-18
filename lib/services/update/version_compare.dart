// 版本比较（纯逻辑，可单测）：以 versionCode 数值为准，严禁字符串比较。

/// 远端是否比本机更新：remoteCode > localCode。
bool isNewerVersion(int localCode, int remoteCode) => remoteCode > localCode;

/// 解析 versionCode：容忍非数字 / 缺失，缺失记作 0（安全降级为“不更新”）。
int parseVersionCode(dynamic v) {
  if (v == null) return 0;
  if (v is int) return v;
  if (v is num) return v.toInt();
  final s = v.toString().trim();
  if (s.isEmpty) return 0;
  return int.tryParse(s) ?? 0;
}
