import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'user_package.dart';

/// ASR-228 · D3 落库件 1 的「文件入口」底座。
///
/// 为什么不是系统文件选择器：本 App 零新增依赖（`file_picker`/SAF 会带进原生插件、
/// 体积与构建风险都不小），而 Android 13+ 的分区存储又不让随便翻 Downloads。
/// 所以走**应用自有目录**：用户用任意文件管理器把 CSV/JSON 放进
/// `<app documents>/user_packages/`，这里列出来供选择；模板也能一键写到同一目录，
/// 形成「拿模板 → 离线编辑 → 放回目录 → 导入」的闭环。
///
/// 构造时可注入 [dir]（测试用临时目录），生产走 path_provider。
class UserPackageFiles {
  UserPackageFiles({String? dir}) : _dirOverride = dir;

  static const String dirName = 'user_packages';

  final String? _dirOverride;

  Future<String> resolveDir() async {
    if (_dirOverride != null) {
      final d = Directory(_dirOverride);
      if (!await d.exists()) await d.create(recursive: true);
      return d.path;
    }
    final base = await getApplicationDocumentsDirectory();
    final d = Directory('${base.path}/$dirName');
    if (!await d.exists()) await d.create(recursive: true);
    return d.path;
  }

  /// 目录里可导入的文件（.csv/.json，按修改时间倒序）。
  Future<List<UserPackageFile>> list() async {
    final dir = Directory(await resolveDir());
    final out = <UserPackageFile>[];
    await for (final e in dir.list()) {
      if (e is! File) continue;
      final name = e.uri.pathSegments.last;
      final lower = name.toLowerCase();
      if (!lower.endsWith('.csv') && !lower.endsWith('.json') &&
          !lower.endsWith('.txt')) {
        continue;
      }
      final stat = await e.stat();
      out.add(UserPackageFile(name: name, path: e.path, bytes: stat.size, modified: stat.modified));
    }
    out.sort((a, b) => b.modified.compareTo(a.modified));
    return out;
  }

  Future<String> read(UserPackageFile f) => File(f.path).readAsString();

  /// 把模板写成文件（UTF-8，带 BOM 与否都不影响解析器），返回落点路径。
  Future<String> writeTemplate({bool json = false}) async {
    final dir = await resolveDir();
    final name = json ? 'chunkspoke-模板.json' : 'chunkspoke-模板.csv';
    final p = '$dir${Platform.pathSeparator}$name';
    await File(p).writeAsString(
        json ? userPackageJsonTemplate() : userPackageCsvTemplate(),
        flush: true);
    return p;
  }
}

class UserPackageFile {
  final String name;
  final String path;
  final int bytes;
  final DateTime modified;

  const UserPackageFile({
    required this.name,
    required this.path,
    required this.bytes,
    required this.modified,
  });

  String get sizeText => bytes >= 1024 ? '${(bytes / 1024).toStringAsFixed(1)} KB' : '$bytes B';
}
