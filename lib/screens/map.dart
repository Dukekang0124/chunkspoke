import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'dart:async';
import '../models/content_pack.dart';
import '../services/chunk_asset.dart';
import '../services/crash_log.dart';
import '../services/loaders.dart';
import '../services/license_state.dart';
import '../services/progress_guard.dart';
import '../services/scene_progression.dart';
import '../services/user_package.dart';
import '../services/user_package_store.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';
import 'diagnostics.dart';
import 'level.dart';
import 'license_activate.dart';
import 'review.dart';
import 'free_build_screen.dart';
import 'user_import_screen.dart';
import 'user_package_detail_screen.dart';

import '../ui/labels.dart';
import '../ui/count_up.dart';
import '../ui/motion.dart';
import '../ui/pressable.dart';

String _cn(Level lv) => sceneCn(lv.theme);

/// 难度分组（按**主线顺序**切三档：入门 / 进阶 / 挑战）。
///
/// ASR-208：可选模块（生存 S0）不占三档名额，单独成组置顶 —— 它插在链首，
/// 若仍按原始下标切档，A–T 的分档会被整体悄悄挪一位（入门会吞掉 H、挑战少一关）。
const List<(String, int, int)> _tiers = [
  ('入门', 0, 9),
  ('进阶', 9, 18),
  ('挑战', 18, 999),
];

/// 主线序号 = 原始下标减去它前面的可选模块数（A 仍是 0，T 仍是 19）。
int _mainIndex(List<Level> levels, int index) {
  var n = 0;
  for (var i = 0; i < index; i++) {
    if (!levels[i].optional) n++;
  }
  return n;
}

class MapScreen extends StatefulWidget {
  const MapScreen({super.key});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> with WidgetsBindingObserver {
  Future<_MapData>? _future;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _future = _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// ASR-211 修复 3（时机②）：回前台先把全模块断点按台账归位，再刷新地图。
  /// 节流与重入由 [ProgressGuard] 兜；归位真改了东西才重新取数，避免无谓重建。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed || !mounted) return;
    final progress = Provider.of<ProgressService>(context, listen: false);
    final content = Provider.of<ContentPack>(context, listen: false);
    unawaited(ProgressGuard.run(progress, content, reason: 'resume')
        .then((r) {
      if (!mounted || r == null || r.healed == 0) return;
      setState(() => _future = _load());
    })
        .catchError((Object e, StackTrace st) {
      CrashLog.write('MapScreen.resume: $e', st);
    }));
  }

  /// 两条轴各取所需：
  ///  - levelMastered：场景解锁/推进（旧关卡轴，继续保留）；
  ///  - learned/assetMastered：W2-1 所有「已掌握/已学完」计数（资产轴）。
  Future<_MapData> _load() async {
    final progress = Provider.of<ProgressService>(context, listen: false);
    final content = Provider.of<ContentPack>(context, listen: false);
    final levelMastered = (await progress.chunkStore.allMasteredKeys()).toSet();
    final rows = await progress.chunkStore.allRows();
    final contentIds = <String>{
      for (final lv in content.levels)
        for (final c in lv.chunks) c.id,
    };
    final learned = <String>{
      for (final r in rows)
        if (contentIds.contains(r.chunkKey) &&
            r.assetState != ChunkAssetState.learning)
          r.chunkKey,
    };
    final assetMastered = rows
        .where((r) =>
            contentIds.contains(r.chunkKey) &&
            r.assetState == ChunkAssetState.mastered)
        .length;
    final nowMs = progress.now.millisecondsSinceEpoch;
    final due = await progress.chunkStore.dueChunkKeys(nowMs);
    final next = await progress.chunkStore.nextDueTimestamp(nowMs);
    return _MapData(
      levelMastered: levelMastered,
      learned: learned,
      assetMastered: assetMastered,
      due: due,
      nextDue: next,
    );
  }

  /// 从会话/复习返回后刷新计数：ProgressService 非 ChangeNotifier，
  /// 必须显式重建，否则首页计数停留在进入前的值（S12）。
  void _reload() {
    if (!mounted) return;
    final next = _load();
    // 不能用箭头函数：赋值表达式的返回值是 Future，setState 会直接抛错且不重建。
    setState(() {
      _future = next;
    });
  }

  @override
  Widget build(BuildContext context) {
    final content = Provider.of<ContentPack>(context);
    final levels = content.levels;
    // 1.6.0（LIC-1）：地图只读 gate 结论，不自建判断。
    final lic = Provider.of<LicenseState?>(context, listen: true);

    return Scaffold(
      appBar: AppBar(title: const Text('练习')),
      body: FutureBuilder<_MapData>(
        future: _future,
        builder: (ctx, snap) {
          final data = snap.data;
          final mastered = data?.levelMastered ?? <String>{};
          final learned = data?.learned ?? <String>{};
          final assetMastered = data?.assetMastered ?? 0;
          final due = data?.due ?? const <String>[];
          final nextDue = data?.nextDue;
          final progress = Provider.of<ProgressService>(context);
          int masteredIn(Level lv) => masteredInLevel(lv, mastered);
          bool unlockedAt(int i) =>
              isSceneUnlocked(levels, i, mastered, allowed: lic?.allowsLevel);
          bool licenseLockedAt(int i) => lic != null && !lic.allowsLevel(i);
          String lockedHintFor(int i) {
            final prev = levels[i - 1];
            return '先完成「${_cn(prev)}」：本场景达标 '
                '${sceneUnlockTarget(prev)}/${prev.chunks.length} 块解锁'
                '（当前 ${masteredIn(prev)}/${prev.chunks.length}）';
          }

          // A1：自由造句沙盒——累计学完（资产轴非新学）≥10 块全局解锁。
          final learnedChunks = <Chunk>[];
          for (final lv in levels) {
            for (final c in lv.chunks) {
              if (learned.contains(c.id)) learnedChunks.add(c);
            }
          }
          final combo = learnedChunks.length > 1
              ? learnedChunks.length * (learnedChunks.length - 1) ~/ 2
              : 0;
          final sandboxOn = freeBuildUnlocked(learnedChunks.length);

          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              TodayCard(
                  levelMastered: mastered,
                  learned: learned,
                  assetMasteredCount: assetMastered,
                  content: content,
                  due: due,
                  nextDue: nextDue,
                  dailyNew: progress.dailyNewCount,
                  allowed: lic?.allowsLevel,
                  onReturn: _reload),
              const SizedBox(height: 12),
              _FreeBuildCard(
                learnedCount: learnedChunks.length,
                combo: combo,
                unlocked: sandboxOn,
                learnedChunks: learnedChunks,
                onReturn: _reload,
              ),
              const SizedBox(height: 18),
              // ASR-223 v2 = D3 正式 UI 第一片，ASR-229 D4 件 3：分区列真包。
              // D3 落库后同一分区读「我的模块」自己的包档案；点包名进只读详情（含级联删除），
              // 点卡片进导入器（三入口 + 确认步 + 落库）。本组件只读不写，钉测见
              // test/userpack_map_entry_test.dart。
              _UserModuleSection(onReturn: _reload),
              const SizedBox(height: 18),
              if (levels.any((lv) => lv.optional)) ...[
                const _TierHeader('生存'),
                const SizedBox(height: 8),
                for (final e in levels.asMap().entries)
                  if (e.value.optional)
                    _SceneRow(
                      level: e.value,
                      index: e.key,
                      unlocked: unlockedAt(e.key),
                      licenseLocked: licenseLockedAt(e.key),
                      lockedHint: null,
                      masteredCount: masteredIn(e.value),
                      onReturn: _reload,
                    ),
                const SizedBox(height: 14),
              ],
              for (final (label, start, end) in _tiers)
                if (start < levels.where((lv) => !lv.optional).length) ...[
                  _TierHeader(label),
                  const SizedBox(height: 8),
                  ...levels
                      .asMap()
                      .entries
                      .where((e) => !e.value.optional &&
                          _mainIndex(levels, e.key) >= start &&
                          _mainIndex(levels, e.key) < end)
                      .map((e) => _SceneRow(
                            level: e.value,
                            index: e.key,
                            unlocked: unlockedAt(e.key),
                            licenseLocked: licenseLockedAt(e.key),
                            lockedHint: e.key > 0 ? lockedHintFor(e.key) : null,
                            masteredCount: masteredIn(e.value),
                            onReturn: _reload,
                          )),
                  const SizedBox(height: 14),
                ],
            ],
          );
        },
      ),
    );
  }
}

class _TierHeader extends StatelessWidget {
  final String label;
  const _TierHeader(this.label);
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(left: 4, bottom: 2),
        child: Row(
          children: [
            Container(
                width: 4,
                height: 16,
                decoration: BoxDecoration(
                    color: kPrimary, borderRadius: BorderRadius.circular(2))),
            const SizedBox(width: 8),
            Text(label,
                style: TextStyle(
                    color: kPrimary,
                    fontSize: 15,
                    fontWeight: FontWeight.w600)),
          ],
        ),
      );
}

/// A1：自由造句沙盒入口卡片——累计学完 ≥10 块全局解锁，可点击进入沙盒。
class _FreeBuildCard extends StatelessWidget {
  final int learnedCount;
  final int combo;
  final bool unlocked;
  final List<Chunk> learnedChunks;
  final VoidCallback onReturn;
  const _FreeBuildCard({
    required this.learnedCount,
    required this.combo,
    required this.unlocked,
    required this.learnedChunks,
    required this.onReturn,
  });

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: unlocked ? 1 : 0.65,
      child: GestureDetector(
        onTap: unlocked
            ? () async {
                await Navigator.push(
                  context,
                  MaterialPageRoute(
                      builder: (_) =>
                          FreeBuildScreen(learnedChunks: learnedChunks)),
                );
                onReturn();
              }
            : null,
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [kPrimaryDeep, kCard],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
                color: unlocked
                    ? kPrimary.withValues(alpha: 0.6)
                    : kBorder),
          ),
          child: Row(
            children: [
              Icon(Icons.auto_awesome, color: kPrimary, size: 28),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('自由造句沙盒 · 累计可组合句子 $combo+',
                        style: TextStyle(
                            color: kText,
                            fontSize: 16,
                            fontWeight: FontWeight.w700)),
                    const SizedBox(height: 4),
                    Text(
                      unlocked
                          ? '已学完 $learnedCount 块，选块拼句、开口判定'
                          : '累计学完 10 块解锁（当前 $learnedCount/10）',
                      style:
                          TextStyle(color: kTextMuted, fontSize: 12),
                    ),
                  ],
                ),
              ),
              Icon(unlocked ? Icons.arrow_forward_ios : Icons.lock,
                  size: 16, color: unlocked ? kPrimary : kTextFaint),
            ],
          ),
        ),
      ),
    );
  }
}

/// ASR-223 v2 / ASR-228 D3 / ASR-229 D4 件 3：「我的模块」分区 = 真包列表 + 导入入口。
///
/// D4 起这里读包档案列表（`UserPackageStore.listPackages()`，纯读）把用户自己导进来的包
/// 列成分区里的行；档案坏掉的包不在列表里（列表侧为了不炸 UI 会跳过），
/// 但**不静默消失**——自检「我的模块」区块会把它连它的行一起打出来（D4 件 1 的连坐项）。
///
/// 红线从 v2 的「只导航」升级成 D4 的「只读不写」，仍然靠结构保证：
/// 本组件不许出现落库写入口、不许删包、不许碰断点与官方台账 API——
/// 写入只发生在导入器的确认步，删除只发生在详情页里用户明确确认之后。
/// 两条都钉在 `test/userpack_map_entry_test.dart`。
class _UserModuleSection extends StatefulWidget {
  final VoidCallback onReturn;
  const _UserModuleSection({required this.onReturn});

  @override
  State<_UserModuleSection> createState() => _UserModuleSectionState();
}

class _UserModuleSectionState extends State<_UserModuleSection> {
  Future<UserPackageInventory>? _inventory;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() {
    // 只读盘点：不写库、不碰断点、不动官方口径。
    // ASR-233：这里必须用盘点而不是「好包列表」——坏档案被列表跳过，
    // 分区就会无声少一个包，用户以为数据没了。坏档案要在这里看得见。
    final store = UserPackageStore(
        Provider.of<ProgressService>(context, listen: false).database);
    _inventory = store.inspect();
  }

  Future<void> _openDiagnostics() async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const DiagnosticsScreen()),
    );
    if (!mounted) return;
    setState(_reload);
  }

  Future<void> _openImport() async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const UserImportScreen()),
    );
    if (!mounted) return;
    setState(_reload);
    widget.onReturn();
  }

  Future<void> _openDetail(UserPackageRecord rec) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
          builder: (_) => UserPackageDetailScreen(moduleKey: rec.moduleKey)),
    );
    if (!mounted) return;
    setState(_reload);
    widget.onReturn();
  }

  String _importedDate(int ms) {
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    return '${d.month}月${d.day}日';
  }

  /// ASR-233：读不出来的档案要在分区里明说，并给一条去诊断的路。
  /// 不猜内容、不自动删——自检判红后由用户决定重新导入还是清掉。
  Widget _corruptNotice(int n) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: InkWell(
          key: const Key('userCorruptNotice'),
          borderRadius: BorderRadius.circular(14),
          onTap: _openDiagnostics,
          child: Container(
            padding: const EdgeInsets.fromLTRB(14, 10, 12, 10),
            decoration: BoxDecoration(
              color: kErrorTint,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: kError),
            ),
            child: Row(
              children: [
                Icon(Icons.report_gmailerrorred, color: kError, size: 20),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('$n 份包档案读不出来',
                          style: TextStyle(
                              color: kText,
                              fontSize: 14,
                              fontWeight: FontWeight.w600)),
                      const SizedBox(height: 2),
                      Text('包还在本机，只是档案坏了，所以这里列不出内容。'
                          '去诊断看详情；重新导入同名模块即可修好。',
                          style: TextStyle(color: kTextMuted, fontSize: 12)),
                    ],
                  ),
                ),
                Icon(Icons.arrow_forward_ios, size: 14, color: kError),
              ],
            ),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _TierHeader('我的模块'),
        const SizedBox(height: 8),
        InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: _openImport,
          child: Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: kCard,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: kBorder),
            ),
            child: Row(
              children: [
                Icon(Icons.upload_file, color: kPrimary, size: 26),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('导入我自己的词块（CSV / JSON）',
                          style: TextStyle(
                              color: kText,
                              fontSize: 16,
                              fontWeight: FontWeight.w700)),
                      const SizedBox(height: 4),
                      Text('文件 / 粘贴 / 模板三个入口；确认前不写入，'
                          '确认后只进「我的模块」',
                          style: TextStyle(color: kTextMuted, fontSize: 12)),
                    ],
                  ),
                ),
                Icon(Icons.arrow_forward_ios, size: 16, color: kPrimary),
              ],
            ),
          ),
        ),
        // D4 件 3：真包体列表（已导入才出现；没导入时一句话说明，不留空白分区）。
        FutureBuilder<UserPackageInventory>(
          future: _inventory,
          builder: (ctx, snap) {
            final inv = snap.data;
            if (inv == null) {
              return Padding(
                padding: const EdgeInsets.only(top: 10, left: 4),
                child: Text('正在读本机的自定义包…',
                    style: TextStyle(color: kTextFaint, fontSize: 12)),
              );
            }
            final recs = inv.packages;
            if (recs.isEmpty && inv.corruptCount == 0) {
              return Padding(
                padding: const EdgeInsets.only(top: 10, left: 4),
                child: Text('还没有导入过的包。用上面的入口先看模板，'
                    '粘贴或选文件都行，确认前一行都不写。',
                    style: TextStyle(color: kTextFaint, fontSize: 12)),
              );
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(height: 10),
                if (inv.corruptCount > 0) _corruptNotice(inv.corruptCount),
                for (final rec in recs)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(14),
                      onTap: () => _openDetail(rec),
                      child: Container(
                        padding: const EdgeInsets.fromLTRB(14, 10, 12, 10),
                        decoration: BoxDecoration(
                          color: kBg,
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: kBorder),
                        ),
                        child: Row(
                          children: [
                            Icon(Icons.library_books_outlined,
                                color: kPrimary, size: 20),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(rec.moduleName,
                                      style: TextStyle(
                                          color: kText,
                                          fontSize: 15,
                                          fontWeight: FontWeight.w600)),
                                  const SizedBox(height: 2),
                                  Text(
                                      '${rec.chunkCount} 块 · '
                                      '${_importedDate(rec.importedAt)}导入 · '
                                      '不进官方已掌握数与复习排期',
                                      style: TextStyle(
                                          color: kTextMuted, fontSize: 12)),
                                ],
                              ),
                            ),
                            Icon(Icons.arrow_forward_ios,
                                size: 14, color: kTextFaint),
                          ],
                        ),
                      ),
                    ),
                  ),
                if (recs.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(left: 4, top: 2),
                    child: Text('本机 ${recs.length}/$kUserPackageMaxPackages 个包，'
                        '每包上限 $kUserPackageMaxChunks 块；'
                        '同名模块重新导入＝整包替换。',
                        style: TextStyle(color: kTextFaint, fontSize: 12)),
                  ),
              ],
            );
          },
        ),
        const SizedBox(height: 8),
        Padding(
          padding: const EdgeInsets.only(left: 4),
          child: Text('官方模块的已掌握数、复习排期与断点都不因为你导入而改变；'
              '没点「确认导入」之前，这一页一行都不写。',
              style: TextStyle(color: kTextFaint, fontSize: 12)),
        ),
      ],
    );
  }
}

class _SceneRow extends StatelessWidget {
  final Level level;
  final int index;
  final bool unlocked;

  /// 1.6.0：这一关是因授权墙锁住（而不是没学够）。
  final bool licenseLocked;
  final String? lockedHint;
  final int masteredCount;
  final VoidCallback onReturn;
  const _SceneRow(
      {required this.level,
      required this.index,
      required this.unlocked,
      this.licenseLocked = false,
      this.lockedHint,
      required this.masteredCount,
      required this.onReturn});

  Future<void> _open(BuildContext context) async {
    if (!unlocked) {
      if (licenseLocked) {
        // 不打断学习、不弹窗拦截：只给一张说明 sheet。
        await showLicenseWallSheet(
          context,
          title: 'G 关起需要解锁码',
          detail: '生存 S0 + A–F 共 7 个场景（167 块）随便学，永久免费；'
              'G 关起的场景需要一枚解锁码。'
              '你已经学过的内容、复习和评测都不受影响。',
        );
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(lockedHint ?? '先完成上一场景，达标到 80% 解锁'),
        duration: const Duration(seconds: 2),
      ));
      return;
    }
    Motion.of(context).success();
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => LevelScreen(level: level)),
    );
    onReturn();
  }

  @override
  Widget build(BuildContext context) {
    final total = level.chunks.length;
    final ratio = total > 0 ? masteredCount / total : 0.0;
    final done = masteredCount >= sceneUnlockTarget(level);
    final status = done ? '🟢' : (unlocked ? '🟡' : '⚪');
    return Opacity(
      opacity: unlocked ? 1 : 0.5,
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => _open(context),
        child: Container(
          margin: const EdgeInsets.only(bottom: 10),
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
          decoration: BoxDecoration(
            color: kBg,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
                color:
                    done ? kUnlocked.withValues(alpha: 0.6) : kBorder),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  unlocked
                      ? Container(
                          width: 40,
                          height: 40,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: kPrimary.withValues(alpha: 0.15),
                            border: Border.all(
                                color: kPrimary.withValues(alpha: 0.5)),
                          ),
                          child: done
                              ? Icon(Icons.check, color: kUnlocked)
                              : Center(
                                  child: Text('${index + 1}',
                                      style: TextStyle(
                                          color: kPrimary,
                                          fontWeight: FontWeight.w600)),
                                ),
                        )
                      : Icon(Icons.lock, color: kTextFaint),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(_cn(level),
                            style: TextStyle(
                                color: kText,
                                fontSize: 17,
                                fontWeight: FontWeight.w600)),
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            Text('$masteredCount/$total',
                                style: TextStyle(
                                    color: kTextSecondary, fontSize: 13)),
                            const SizedBox(width: 6),
                            Text(status, style: const TextStyle(fontSize: 13)),
                          ],
                        ),
                      ],
                    ),
                  ),
                  // 场景圆环与本场景达标 x/y 同源（关卡轴，仅用于解锁）。
                  MasteryRing(total > 0 ? masteredCount / total : 0, size: 42),
                  const SizedBox(width: 8),
                  if (unlocked)
                    Icon(Icons.arrow_forward_ios,
                        size: 16, color: kTextFaint),
                ],
              ),
              const SizedBox(height: 8),
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: LinearProgressIndicator(
                  value: ratio.clamp(0.0, 1.0),
                  minHeight: 6,
                  backgroundColor: kBorder,
                  valueColor:
                      AlwaysStoppedAnimation(done ? kUnlocked : kPrimary),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class TodayCard extends StatelessWidget {
  /// 关卡轴：只用于场景解锁/推进。
  final Set<String> levelMastered;

  /// 资产轴：已进入复习周期（非 learning）的块，用于“新学”筛选。
  final Set<String> learned;

  /// 资产轴：走完 1/3/7/14 天的块数（W2-1 头部唯一口径）。
  final int assetMasteredCount;
  final ContentPack content;
  final List<String> due;
  final int? nextDue; // 下一次资产复习到期（epoch ms；无则 null）
  final int dailyNew;
  /// 1.6.0（LIC-1）：关卡轴权限（G 起要解锁码）。null = 不设限（与 1.5.x 一致）。
  final bool Function(int index)? allowed;
  final VoidCallback onReturn;
  const TodayCard(
      {super.key,
      required this.levelMastered,
      required this.learned,
      required this.assetMasteredCount,
      required this.content,
      required this.due,
      this.nextDue,
      this.dailyNew = 0,
      this.allowed,
      required this.onReturn});

  @override
  Widget build(BuildContext context) {
    // A3：每日会话瘦身——新学 ≤6（跨场景按序取资产轴尚未学过的块），复习到期优先。
    // 1.6.0（LIC-1）：锁住的场景不参与「新学」抽样，别把用户从免费区抽到墙外。
    final newChunks = <String>[];
    for (var i = 0; i < content.levels.length; i++) {
      if (allowed != null && !allowed!(i)) continue;
      for (final c in content.levels[i].chunks) {
        if (newChunks.length >= 6) break;
        if (!learned.contains(c.id)) newChunks.add(c.id);
      }
      if (newChunks.length >= 6) break;
    }
    final reviewCount = due.length;
    final newCount = newChunks.length;
    final allClear = reviewCount == 0 && newCount == 0;
    final anyLocked =
        content.levels.any((lv) => missingForUnlock(lv, levelMastered) > 0);
    final theme = anyLocked ? '今天开始 · 完成未解锁场景' : '今天也来练一练';
    final target = progressionTarget(content.levels, levelMastered,
        allowed: allowed);
    // 首页「下次复习」直接接资产复习引擎（无到期时展示下一次排期）。
    String nextDueText;
    if (due.isNotEmpty) {
      nextDueText = '今天';
    } else if (nextDue == null) {
      nextDueText = '暂无';
    } else {
      final d = DateTime.fromMillisecondsSinceEpoch(nextDue!);
      nextDueText = '${d.month}月${d.day}日';
    }

    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [kCard, kPrimaryDeep],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: kPrimary.withValues(alpha: 0.45)),
        boxShadow: [
          BoxShadow(
              color: kShadow, blurRadius: 14, offset: const Offset(0, 6)),
        ],
      ),
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: kPrimary,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(theme,
                    style: TextStyle(
                        color: kOnPrimary,
                        fontSize: 13,
                        fontWeight: FontWeight.w600)),
              ),
              const Spacer(),
              Text('今日会话',
                  style: TextStyle(color: kPrimary, fontSize: 13)),
            ],
          ),
          const SizedBox(height: 12),
          CountUpText(assetMasteredCount,
              style: TextStyle(
                  color: kText,
                  fontSize: 22,
                  fontWeight: FontWeight.w700),
              format: (v) => '已掌握 $v 个词块'),
          const SizedBox(height: 6),
          Text(
            '复习 $reviewCount 个 + 新学 $newCount 个 · '
            '已学完 ${learned.length} 块',
            style: TextStyle(color: kTextMuted, fontSize: 13),
          ),
          const SizedBox(height: 4),
          Text(
            '下次复习：$nextDueText',
            style: TextStyle(color: kTextFaint, fontSize: 12),
          ),
          if (due.isNotEmpty) ...[
            const SizedBox(height: 12),
            PressableScale(
              scale: 0.98,
              child: GestureDetector(
                onTap: () async {
                  await Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const ReviewScreen()),
                  );
                  onReturn();
                },
                child: Container(
                  width: double.infinity,
                  padding:
                      const EdgeInsets.symmetric(vertical: 12, horizontal: 14),
                  decoration: BoxDecoration(
                    color: kUnlocked.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: kUnlocked.withValues(alpha: 0.5)),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.replay, color: kUnlocked, size: 18),
                      const SizedBox(width: 8),
                      Text('今日复习 ${due.length} 个词块',
                          style:
                              TextStyle(color: kUnlocked, fontSize: 15)),
                      const Spacer(),
                      Icon(Icons.arrow_forward_ios,
                          size: 14, color: kUnlocked),
                    ],
                  ),
                ),
              ),
            ),
          ],
          if (allClear) ...[
            const SizedBox(height: 12),
            Text('今日已清空，明天见 🎉',
                style: TextStyle(
                    color: kUnlocked,
                    fontSize: 15,
                    fontWeight: FontWeight.w600)),
          ],
          const SizedBox(height: 16),
          PressableScale(
            scale: 0.98,
            enabled: target != null,
            child: SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: kPrimary,
                  foregroundColor: kOnPrimary,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
                onPressed:
                    target == null ? null : () => _openToday(context, target),
                child: Text(target == null ? '已全部通关' : '继续学习：${_cn(target)}',
                    style: const TextStyle(
                        fontSize: 17, fontWeight: FontWeight.w700)),
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _openToday(BuildContext context, Level target) async {
    Motion.of(context).success();
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => LevelScreen(level: target)),
    );
    onReturn();
  }
}

class _MapData {
  final Set<String> levelMastered;
  final Set<String> learned;
  final int assetMastered;
  final List<String> due;
  final int? nextDue;
  const _MapData({
    required this.levelMastered,
    required this.learned,
    required this.assetMastered,
    required this.due,
    required this.nextDue,
  });
}
