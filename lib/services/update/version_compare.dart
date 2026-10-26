// 版本比较（纯逻辑，可单测）：以 versionCode 数值为准，严禁字符串比较。

/// 远端是否比本机更新：remoteCode > localCode。
///
/// 注意：这是**同 ABI 槽位内**的比较原语。跨 ABI 时数值大小不代表「本机能装的那个包」，
/// 判更新请用 [isUpdateForThisDevice]。
bool isNewerVersion(int localCode, int remoteCode) => remoteCode > localCode;

/// split-per-abi 的 ABI 槽位 = versionCode 的千位（由 `tools/stage_release.py` 强制）：
/// 基数 2xxx 直发 = 2、armeabi-v7a(+1000) = 3、arm64-v8a(+2000) = 4、x86_64(+4000) = 6。
int abiSlotOf(int versionCode) => versionCode <= 0 ? 0 : versionCode ~/ 1000;

/// 应用内更新是否适用于本机：**只在同 ABI 槽位内判更新**。
///
/// 线上清单的 `url`/`versionCode` 恒为 arm64 主推荐包（见 `abi-manifest.json` 的 note）。
/// 旧实现直接比数值，会让 v7a 设备（3xxx）看到 4xxx > 3xxx 而弹窗，
/// 下载 57 MB 后交给系统安装器必然 `INSTALL_FAILED_NO_MATCHING_ABIS`——
/// 用户得到的是一个每次都失败、还会 7 天静默重试的坏弹窗。
/// x86_64（6xxx）反之：数值更大所以永不弹，属已登记的既有限制，本函数不改变它。
bool isUpdateForThisDevice(int localCode, int remoteCode) {
  final local = abiSlotOf(localCode);
  final remote = abiSlotOf(remoteCode);
  if (local == 0 || remote == 0) return false;
  if (local != remote) return false;
  return isNewerVersion(localCode, remoteCode);
}


/// 解析 versionCode：容忍非数字 / 缺失，缺失记作 0（安全降级为“不更新”）。
int parseVersionCode(dynamic v) {
  if (v == null) return 0;
  if (v is int) return v;
  if (v is num) return v.toInt();
  final s = v.toString().trim();
  if (s.isEmpty) return 0;
  return int.tryParse(s) ?? 0;
}
