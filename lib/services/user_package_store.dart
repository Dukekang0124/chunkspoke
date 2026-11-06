import 'dart:convert';

import 'chunk_asset.dart';
import 'database.dart';
import 'state_machine.dart';
import 'user_package.dart';

/// ASR-228 · D3 落库件 2：自定义词块包的**唯一写入出口**。
///
/// 三条结构性约束（不靠自觉，靠这里的形状 + `test/user_package_store_test.dart` 钉死）：
///  1. **命名空间**：块行一律 `user:<sha8(front)>`（[UserChunkEntry.chunkKey]），
///     包档案一律 `userpkg.<sha8(moduleKey)>`；官方读路径在库层就被
///     [AppDatabase.kUserKeyExclude] 整体排除，所以这里写多少行都不会进官方计数。
///  2. **不碰断点**：本文件不 import 任何 resume/anchor API，也不调
///     `applyImportedRows`（那条路会为「有 level 归属的块」重算锚点）；
///     `user:` 键不属于任何官方 level，锚点因此不可能被它推动。
///  3. **同事务落盘**：块行 + 包档案在一次 `upsertChunksAndKv` 里写完，
///     不留「档案说 12 块、台账只有 5 行」的半截态。
class UserPackageStore {
  UserPackageStore(this._db, {DateTime Function()? clock})
      : _clock = clock ?? DateTime.now;

  final AppDatabase _db;
  final DateTime Function() _clock;

  /// 已导入的包（按导入时间倒序；空档案自动跳过）。
  Future<List<UserPackageRecord>> listPackages() async {
    final raw = await _db.kvKeysWithPrefix(AppDatabase.kUserPkgKvPrefix);
    final out = <UserPackageRecord>[];
    for (final json in raw) {
      if (json.trim().isEmpty) continue;
      try {
        final r = UserPackageRecord.fromJson(
            jsonDecode(json) as Map<String, dynamic>);
        if (r.entries.isNotEmpty) out.add(r);
      } catch (_) {
        // 档案坏掉不连坐：跳过并留给自检（D4 扩区项）。
      }
    }
    out.sort((a, b) => b.importedAt.compareTo(a.importedAt));
    return out;
  }

  /// 台账里实际存在的 `user:` 行数（与档案对账用）。
  Future<int> userRowCount() async => (await _db.allUserChunks()).length;

  Future<UserPackageRecord?> packageOf(String moduleKey) async {
    final json = await _db.getKv('${AppDatabase.kUserPkgKvPrefix}$moduleKey');
    if (json == null || json.trim().isEmpty) return null;
    try {
      return UserPackageRecord.fromJson(jsonDecode(json) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  /// 落库：把已过闸的校验结果写进本机。返回写入统计与人类可读的一句话。
  ///
  /// 同名模块 = 重新导入：整包替换（旧的行删干净再写），不追加重复块。
  Future<UserImportResult> importValidation(UserPackageValidation v) async {
    if (!v.ok) {
      return UserImportResult.failed(v.firstErrorText);
    }
    final existing = await listPackages();
    final byModule = {for (final r in existing) r.moduleKey: r};

    // 分组：一份表可以带多个 module_name。
    final incoming = <String, List<UserChunkEntry>>{};
    for (final e in v.entries) {
      incoming.putIfAbsent(e.moduleKey, () => <UserChunkEntry>[]).add(e);
    }

    // 名额闸（库层兜底，不只信校验器）：包数 ≤5，单包 ≤200。
    final mergedModules = {...byModule.keys, ...incoming.keys};
    if (mergedModules.length > kUserPackageMaxPackages) {
      return UserImportResult.failed(
          '本机已有 ${byModule.length} 个包，这份还带来 ${incoming.length} 个；'
          '上限 $kUserPackageMaxPackages 个。先删掉一个再导入。');
    }
    for (final e in incoming.entries) {
      if (e.value.length > kUserPackageMaxChunks) {
        return UserImportResult.failed(
            '「${e.value.first.moduleName}」有 ${e.value.length} 块，'
            '超过每包 $kUserPackageMaxChunks 块上限。');
      }
    }

    final now = _clock().millisecondsSinceEpoch;
    final rows = <ChunkRow>[];
    final dropKeys = <String>[];
    final kv = <String, String>{};
    var replaced = 0;
    for (final e in incoming.entries) {
      final old = byModule[e.key];
      if (old != null) {
        // 同名重导：旧行先删，避免改了 front 后留下孤儿行。
        dropKeys.addAll(old.entries.map((x) => x.chunkKey));
        replaced++;
      }
      for (final entry in e.value) {
        rows.add(_rowFor(entry));
      }
      kv['${AppDatabase.kUserPkgKvPrefix}${e.key}'] = jsonEncode(UserPackageRecord(
        moduleKey: e.key,
        moduleName: e.value.first.moduleName,
        entries: e.value,
        importedAt: now,
      ).toJson());
    }
    // 跨包同名块（front 相同）只留一行，防止 chunkKey 撞车互相覆盖。
    final dedup = <String, ChunkRow>{for (final r in rows) r.chunkKey: r};

    if (dropKeys.isNotEmpty) {
      await _db.deleteChunksByKeys(dropKeys.toList());
    }
    await _db.upsertChunksAndKv(dedup.values.toList(), kv);

    final names = [for (final e in incoming.entries) e.value.first.moduleName];
    return UserImportResult(
      ok: true,
      writtenChunks: dedup.length,
      moduleNames: names,
      packagesAfter: mergedModules.length,
      replacedPackages: replaced,
      note: replaced > 0
          ? '已写入 ${dedup.length} 块 · ${names.length} 个模块'
              '（其中 $replaced 个同名模块按新表整包替换）'
          : '已写入 ${dedup.length} 块 · ${names.length} 个模块',
    );
  }

  /// 删包：档案与块行同事务清掉（D4「卸载级联」的库层底座）。
  Future<int> removePackage(String moduleKey) async {
    final rec = await packageOf(moduleKey);
    if (rec == null) return 0;
    await _db.deleteChunksByKeys(rec.entries.map((e) => e.chunkKey).toList());
    await _db.setKv('${AppDatabase.kUserPkgKvPrefix}$moduleKey', '');
    return rec.entries.length;
  }

  /// 新导入的块一律记成「未开始学习」：level=l1、不排期、资产态 learning。
  /// 这样它进不了官方到期队列，也不会被复习引擎抓走。
  ChunkRow _rowFor(UserChunkEntry e) => ChunkRow(
        chunkKey: e.chunkKey,
        level: ChunkLevel.l1,
        dueDate: 0,
        failCount: 0,
        lastScore: 0,
        assetState: ChunkAssetState.learning,
      );
}

/// 一个已导入的包。
class UserPackageRecord {
  final String moduleKey;
  final String moduleName;
  final List<UserChunkEntry> entries;
  final int importedAt;

  const UserPackageRecord({
    required this.moduleKey,
    required this.moduleName,
    required this.entries,
    required this.importedAt,
  });

  int get chunkCount => entries.length;

  Map<String, dynamic> toJson() => {
        'module_key': moduleKey,
        'module_name': moduleName,
        'imported_at': importedAt,
        'entries': [for (final e in entries) e.toJson()],
      };

  factory UserPackageRecord.fromJson(Map<String, dynamic> j) => UserPackageRecord(
        moduleKey: (j['module_key'] ?? '').toString(),
        moduleName: (j['module_name'] ?? '').toString(),
        importedAt: (j['imported_at'] as num?)?.toInt() ?? 0,
        entries: [
          for (final raw in (j['entries'] as List? ?? const []))
            UserChunkEntry.fromJson(
                Map<String, dynamic>.from(raw as Map)),
        ],
      );
}

/// 落库结果。
class UserImportResult {
  final bool ok;
  final int writtenChunks;
  final List<String> moduleNames;
  final int packagesAfter;
  final int replacedPackages;
  final String note;

  const UserImportResult({
    required this.ok,
    this.writtenChunks = 0,
    this.moduleNames = const [],
    this.packagesAfter = 0,
    this.replacedPackages = 0,
    this.note = '',
  });

  UserImportResult.failed(String why)
      : ok = false,
        writtenChunks = 0,
        moduleNames = const [],
        packagesAfter = 0,
        replacedPackages = 0,
        note = why;
}
