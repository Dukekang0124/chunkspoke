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
///  3. **同事务落盘**：删旧行 + 块行 + 包档案在一次 `replaceChunksAndKv` 里写完，
///     不留「档案说 12 块、台账只有 5 行」或「旧行已删、新档案没写」的半截态。
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

  /// ASR-229 · D4 件 1 的连坐项：坏档案**不许静默跳过**。
  ///
  /// `listPackages()` 为了不炸 UI 会跳过解析失败的档案，但"跳过"本身必须可被看见，
  /// 否则用户的包会无声消失（这正是自检该抓的东西）。`inspect()` 把两边都交出来：
  /// 好档案 + 坏档案的 kv 键 + 台账行数与档案块数的差额（差额≠0 就是双源分歧）。
  Future<UserPackageInventory> inspect() async {
    final raw = await _db.kvKeysWithPrefix(AppDatabase.kUserPkgKvPrefix);
    final good = <UserPackageRecord>[];
    final corrupt = <String>[];
    for (final json in raw) {
      if (json.trim().isEmpty) continue;
      try {
        final r = UserPackageRecord.fromJson(
            jsonDecode(json) as Map<String, dynamic>);
        if (r.entries.isEmpty) {
          corrupt.add(r.moduleKey.isEmpty ? '（空档案）' : r.moduleKey);
        } else {
          good.add(r);
        }
      } catch (_) {
        corrupt.add('（无法解析的档案）');
      }
    }
    good.sort((a, b) => b.importedAt.compareTo(a.importedAt));
    final rows = await _db.allUserChunks();
    final rowKeys = {for (final r in rows) r.chunkKey};
    // 档案声明的键去重：同一个 front 理论上只属一个包（归属闸已挡），但历史撞名/手改库
    // 可能让多份档案声明同一键，按集合算才不会虚增 declared。
    final declaredKeys = <String>{for (final r in good) for (final e in r.entries) e.chunkKey};
    final declared = declaredKeys.length;
    // 台账里出现但没有任何档案声明的 user 行（手改库/删包半途都算）。
    final stray = rows.where((r) => !declaredKeys.contains(r.chunkKey)).length;
    // 档案声明了、台账里却没有的键（半截写入/外部删行）。用集合差，不用算术差——
    // 算术差会被「一边缺、一边多」互相抵消掩盖（缺 B 又多 C 时 declared==rows 却其实不一致）。
    final missing = declaredKeys.difference(rowKeys).length;
    return UserPackageInventory(
      packages: good,
      corruptCount: corrupt.length,
      userRowCount: rows.length,
      declaredChunks: declared,
      missingRows: missing,
      strayRows: stray,
    );
  }

  /// 台账里实际存在的 `user:` 行数（与档案对账用）。
  Future<int> userRowCount() async => (await _db.allUserChunks()).length;

  /// ASR-233：按档案补齐**缺失**的台账行（备份恢复 / 半截写入的自愈口）。
  ///
  /// 为什么必须有它：备份件的 `kv` 会带走 `userpkg.*` 档案，但 `chunks` 走官方口径
  /// （库层排除 `user:`），所以换机/清数据后合并备份只回来档案、不回来行 ⇒
  /// 自检判红「档案有、台账无」，分区里看得见包、点进去没有行。
  ///
  /// 三条边界（钉测见 `test/userpack_backup_test.dart`）：
  ///  1. 只补缺行，既有行一字不动（不覆盖任何进度）；
  ///  2. 坏档案跳过——读不出来的东西不凭猜测重建，留给自检判红；
  ///  3. 官方口径完全不碰（写的仍全是 `user:` 键，一次事务落盘）。
  /// 如实说明：user 块的学习进度不在备份件里，补回来的行按「未开始学习」记。
  Future<int> rebuildMissingRows() async {
    final inv = await inspect();
    if (inv.missingRows == 0) return 0;
    final seen = {for (final r in await _db.allUserChunks()) r.chunkKey};
    final rows = <ChunkRow>[];
    for (final rec in inv.packages) {
      for (final e in rec.entries) {
        if (!seen.add(e.chunkKey)) continue;
        rows.add(_rowFor(e));
      }
    }
    if (rows.isEmpty) return 0;
    await _db.upsertChunksAndKv(rows, const {});
    return rows.length;
  }

  Future<UserPackageRecord?> packageOf(String moduleKey) async {
    final json = await _db.getKv('${AppDatabase.kUserPkgKvPrefix}$moduleKey');
    if (json == null || json.trim().isEmpty) return null;
    try {
      return UserPackageRecord.fromJson(jsonDecode(json) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  /// ASR-233 深度自查修复：备份恢复的**档案消毒闸**（licensed 机器专用）。
  ///
  /// 未授权机器在通道层就把 `userpkg.*` 整段跳过（ignoredUserArchives），到不了这里。
  /// 授权机器恢复备份时，旧写法把档案 JSON 原样写回 ⇒ 手改件能绕过导入校验器与名额闸
  /// （塞 6 个包 / 单包 300 块 / 超长脏字符 / 与本机包撞名）。这里对每份**新**档案
  /// （本机已有的不覆盖、不算新）统一过闸，只放行 canonical 重编码后的干净档案：
  ///  · 解析 + 模块键自洽（kv 后缀 == rec.moduleKey == userModuleKey(name)）；
  ///  · 条目数 1..200；逐条过 [normalizeUserEntry]（字段闸 + 归属本模块）；
  ///  · 名额：本机已有包 + 本批新收 ≤ 5；
  ///  · 撞名：档案内 / 档案间 / 与本机既有包，同一 front 只能属一个包（撞名整份拒收）。
  /// 整份不可用 → skippedArchives++；个别条目坏但整份仍收 → skippedEntries++。
  /// 只读本机包列表，不写库；写由调用方按 accepted 执行（与通道「只补不覆盖」一致）。
  Future<UserArchiveAdoption> adoptUserArchives(
      Map<String, String> incomingArchives) async {
    final local = await listPackages();
    final localModuleKeys = {for (final r in local) r.moduleKey};
    var freeSlots = kUserPackageMaxPackages - local.length;
    final reserved = <String>{
      for (final r in local) for (final e in r.entries) e.chunkKey,
    };
    final accepted = <String, String>{};
    var skippedArchives = 0, skippedEntries = 0;
    final keys = incomingArchives.keys.toList()..sort();
    for (final kvKey in keys) {
      final suffix = kvKey.substring(AppDatabase.kUserPkgKvPrefix.length);
      UserPackageRecord rec;
      try {
        rec = UserPackageRecord.fromJson(
            jsonDecode(incomingArchives[kvKey]!) as Map<String, dynamic>);
      } catch (_) {
        skippedArchives++;
        continue;
      }
      if (rec.moduleKey.isEmpty ||
          rec.moduleKey != suffix ||
          rec.moduleKey != userModuleKey(rec.moduleName) ||
          rec.entries.isEmpty ||
          rec.entries.length > kUserPackageMaxChunks ||
          localModuleKeys.contains(rec.moduleKey) ||
          freeSlots <= 0) {
        skippedArchives++;
        continue;
      }
      final good = <UserChunkEntry>[];
      final seen = <String>{};
      var localBad = 0;
      var collision = false;
      for (final e in rec.entries) {
        final norm =
            normalizeUserEntry(e.toJson(), expectedModule: rec.moduleName);
        if (norm == null) {
          localBad++;
          continue;
        }
        if (reserved.contains(norm.chunkKey) || !seen.add(norm.chunkKey)) {
          collision = true;
          break;
        }
        good.add(norm);
      }
      if (collision || good.isEmpty) {
        // 整份拒收：本份内已数的坏条目随整份作废，不并入 skippedEntries（诚实计数）。
        skippedArchives++;
        continue;
      }
      skippedEntries += localBad;
      freeSlots--;
      localModuleKeys.add(rec.moduleKey);
      reserved.addAll(good.map((e) => e.chunkKey));
      accepted[kvKey] = jsonEncode(UserPackageRecord(
        moduleKey: rec.moduleKey,
        moduleName: rec.moduleName,
        entries: good,
        importedAt: rec.importedAt,
      ).toJson());
    }
    return UserArchiveAdoption(
      accepted: accepted,
      skippedArchives: skippedArchives,
      skippedEntries: skippedEntries,
    );
  }

  /// 落库：把已过闸的校验结果写进本机。返回写入统计与人类可读的一句话。
  ///
  /// 同名模块 = 重新导入：整包替换（旧的行删干净再写），不追加重复块。
  ///
  /// ASR-233 付费门：`allowed` **必填**，不默认——逼每个调用方表态。库层也判一遍，
  /// 是因为 UI 门能被绕（备份通道、未来新入口、测试直调）。判据由调用方注入，
  /// 库层不依赖 LicenseState，免得 store 拖上授权装配。
  /// 「恢复本机已有档案」（[rebuildMissingRows]）不走这条路，不受门影响：挡它会让
  /// 老用户清数据后回不来（与 D1 同款不可逆伤害）。
  Future<UserImportResult> importValidation(
    UserPackageValidation v, {
    required bool allowed,
  }) async {
    if (!allowed) {
      return UserImportResult.blockedByLicense();
    }
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

    // 名额闸（库层兜底，不只信校验器）：本数 ≤5，单本 ≤200。
    final mergedModules = {...byModule.keys, ...incoming.keys};
    if (mergedModules.length > kUserPackageMaxPackages) {
      return UserImportResult.failed(
          '手机上已经有 ${byModule.length} 个英语本，这次还要多 ${incoming.length} 个；'
          '最多只能放 $kUserPackageMaxPackages 个。先删掉一本再存。');
    }
    for (final e in incoming.entries) {
      if (e.value.length > kUserPackageMaxChunks) {
        return UserImportResult.failed(
            '「${e.value.first.moduleName}」有 ${e.value.length} 句，'
            '一本最多 $kUserPackageMaxChunks 句。');
      }
    }

    // 跨包同名块归属闸：chunkKey 只由 front 决定，同一个 front 只能属于一个包。
    // 否则 B 包导入会顶掉 A 包的同名行，日后删 B / 重导 B 又把 A 仍声明的行删掉 ⇒
    // missingRows、自检判红、A 包静默丢块（深度自查实测）。写库前挡住，让用户改 front
    // 或并入原包。同名模块重导（owner == 本模块）不算冲突——那是整包替换，下面会删旧写新。
    final ownerOf = <String, String>{};
    for (final r in existing) {
      for (final e in r.entries) {
        ownerOf[e.chunkKey] = r.moduleKey;
      }
    }
    for (final grp in incoming.entries) {
      for (final e in grp.value) {
        final owner = ownerOf[e.chunkKey];
        if (owner != null && owner != grp.key) {
          final ownerName = byModule[owner]?.moduleName ?? owner;
          return UserImportResult.failed(
              '「${e.front}」已经在「$ownerName」里了。同一句只能放在一个本子里：'
              '改一下这句，或者把它并到「$ownerName」里再存。');
        }
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
    // 上面的归属闸已挡住「与既有别的包撞名」，校验器也挡住「同一份表内撞名」，
    // 所以这里通常不会真的折叠；保留作为最后一道防线。
    final dedup = <String, ChunkRow>{for (final r in rows) r.chunkKey: r};

    // 删旧行 + 写新行 + 写档案同一事务：进程中途被杀不留「旧行已删、新档案没写」的半截态。
    await _db.replaceChunksAndKv(
      deleteKeys: dropKeys.toList(),
      upsertRows: dedup.values.toList(),
      kv: kv,
    );

    final names = [for (final e in incoming.entries) e.value.first.moduleName];
    return UserImportResult(
      ok: true,
      writtenChunks: dedup.length,
      moduleNames: names,
      packagesAfter: mergedModules.length,
      replacedPackages: replaced,
      note: replaced > 0
          ? '存好了 ${dedup.length} 句 · ${names.length} 本'
              '（其中 $replaced 本同名，已用这次的替换掉）'
          : '存好了 ${dedup.length} 句 · ${names.length} 本',
    );
  }

  /// 删包：档案与块行同事务清掉（D4「卸载级联」的库层底座）。
  ///
  /// 只删**本包独占**的行：若某个 front 还被别的包声明（历史撞名 / 手改库留下的共享行），
  /// 删掉它会让那个包 missingRows、自检判红。所以先算出其他包仍声明的键，跳过它们。
  /// 返回实际清掉的台账行数（共享行不计——它仍属于别的包）。
  Future<int> removePackage(String moduleKey) async {
    final rec = await packageOf(moduleKey);
    if (rec == null) return 0;
    final others = await listPackages();
    final shared = <String>{
      for (final r in others)
        if (r.moduleKey != moduleKey)
          for (final e in r.entries) e.chunkKey,
    };
    final drop = rec.entries
        .map((e) => e.chunkKey)
        .where((k) => !shared.contains(k))
        .toList();
    // 删行 + 清档案同一事务（空档案串 = 墓碑），不留「档案没了、行还在」的孤儿态。
    await _db.replaceChunksAndKv(
      deleteKeys: drop,
      upsertRows: const [],
      kv: {'${AppDatabase.kUserPkgKvPrefix}$moduleKey': ''},
    );
    return drop.length;
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

/// 自检扩区用的档案盘点（D4 件 1）。
class UserPackageInventory {
  final List<UserPackageRecord> packages;
  final int corruptCount;
  final int userRowCount;
  final int declaredChunks;

  /// 档案声明了块、台账里却没有对应行（>0 = 半截写入或外部改动）。
  final int missingRows;

  /// 台账里有 user 行、但没有任何档案声明（删包半途/手改库）。
  final int strayRows;

  const UserPackageInventory({
    required this.packages,
    required this.corruptCount,
    required this.userRowCount,
    required this.declaredChunks,
    required this.missingRows,
    required this.strayRows,
  });

  int get packageCount => packages.length;
  bool get consistent =>
      corruptCount == 0 && missingRows == 0 && strayRows == 0 &&
      userRowCount == declaredChunks;

  Map<String, Object?> toJson() => {
        'packages': packageCount,
        'declaredChunks': declaredChunks,
        'userRows': userRowCount,
        'corruptArchives': corruptCount,
        'missingRows': missingRows,
        'strayRows': strayRows,
        'consistent': consistent,
      };
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

  /// ASR-233：被付费门挡下（不是校验失败、也不是名额不足）。UI 用它记埋点。
  final bool gated;

  const UserImportResult({
    required this.ok,
    this.writtenChunks = 0,
    this.moduleNames = const [],
    this.packagesAfter = 0,
    this.replacedPackages = 0,
    this.note = '',
    this.gated = false,
  });

  UserImportResult.failed(String why)
      : ok = false,
        writtenChunks = 0,
        moduleNames = const [],
        packagesAfter = 0,
        replacedPackages = 0,
        note = why,
        gated = false;

  /// 库层兜底被门挡下：零写入，文案与墙 sheet 同一口径。
  UserImportResult.blockedByLicense()
      : ok = false,
        writtenChunks = 0,
        moduleNames = const [],
        packagesAfter = 0,
        replacedPackages = 0,
        note = '存到我的英语本需要解锁码：整理和预览一直免费，保存时才需要。'
            '你已经存进来的句子、学习记录和删除都不受影响。',
        gated = true;
}

/// 备份恢复档案消毒闸的结果（ASR-233 深度自查）。
class UserArchiveAdoption {
  /// 通过闸的档案：kvKey → canonical 重编码 JSON（调用方只写这些）。
  final Map<String, String> accepted;

  /// 整份拒收的档案数（解析失败 / 模块键不自洽 / 超 200 / 名额满 / 撞名 / 全坏）。
  final int skippedArchives;

  /// 被收档案里剔除的坏条目数（字段闸不过；整份仍收其余好条目）。
  final int skippedEntries;

  const UserArchiveAdoption({
    required this.accepted,
    required this.skippedArchives,
    required this.skippedEntries,
  });
}
