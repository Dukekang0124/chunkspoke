import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart' show getDatabasesPath;

/// 1.5.10（#209 通道版）· 老用户身份判据（D1）。
///
/// 判据只有一条：**首启时 `chunkspoke.db` 文件在不在**。结论落在**库外**的
/// `legacy.flag` 上，写过一次就永不重写（幂等）。
///
/// 为什么不能放 kv：`kv` 表在 `chunkspoke.db` 里，为了写标记而去开库，判据自己
/// 就把 DB 文件造出来了 → 全员判成老用户，1.6.0 的内容墙当场失效（方案 §8-4 反例）。
///
/// 不可逆点：清数据会连 `legacy.flag` 一起抹掉，所以 1.5.10 的导出件必须带
/// [kLegacyFlagYes]，1.6.0 的导入流程在**开库之前**用它把身份写回去（D1）。
const String kLegacyFlagName = 'legacy.flag';
const String kLegacyFlagYes = 'v1:legacy=1';
const String kLegacyFlagNo = 'v1:legacy=0';

class LegacyGate {
  LegacyGate({
    required this.supportDir,
    required this.dbExists,
    File? flagFile,
  }) : flagFile = flagFile ?? File('${supportDir.path}/$kLegacyFlagName');

  /// 应用私有目录（`path_provider` 的 support 目录，非 DB 目录）。
  final Directory supportDir;

  /// **只判存在，不开库**；注入以便单测断言「导入路径没有调用它」。
  final Future<bool> Function() dbExists;

  final File flagFile;

  static bool isLegacy(String? raw) => raw == kLegacyFlagYes;

  Future<String?> readRaw() async {
    try {
      if (!await flagFile.exists()) return null;
      final raw = (await flagFile.readAsString()).trim();
      return raw.isEmpty ? null : raw;
    } catch (_) {
      // 读失败按「没有」处理：下一条路径会重新判一次，不会把老用户锁死。
      return null;
    }
  }

  /// 首启判据：已有值直接采用、**永不重写**；无值才探一次 DB 文件。
  Future<String> bootstrap() async {
    final cur = await readRaw();
    if (cur != null) return cur;
    final exists = await dbExists();
    final v = exists ? kLegacyFlagYes : kLegacyFlagNo;
    await _write(v);
    return v;
  }

  /// 导入通道（D1）：当前还不是 `legacy=1` 时才允许改写；写点在任何开库动作之前。
  /// 返回是否真的改写了。
  Future<bool> adoptFromImport(String raw) async {
    if (!isLegacy(raw)) return false;
    final cur = await readRaw();
    if (cur == kLegacyFlagYes) return false;
    await _write(kLegacyFlagYes);
    return true;
  }

  Future<void> _write(String v) async {
    try {
      await supportDir.create(recursive: true);
      await flagFile.writeAsString(v, flush: true);
    } catch (_) {
      // 写失败不影响启动；下次首启会再判一次。
    }
  }
}

/// 生产装配：support 目录放标记，DB 路径只做存在性检查。
Future<LegacyGate> openLegacyGate() async {
  final support = await getApplicationSupportDirectory();
  return LegacyGate(
    supportDir: support,
    dbExists: () async {
      try {
        final dir = await getDatabasesPath();
        return await File('$dir/chunkspoke.db').exists();
      } catch (_) {
        return false;
      }
    },
  );
}
