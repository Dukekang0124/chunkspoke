import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/chunk_asset.dart';
import '../services/database.dart';
import '../services/loaders.dart';
import '../services/session.dart';
import '../services/user_package.dart';
import '../services/user_package_store.dart';
import '../steps/practice_loop.dart';
import '../ui/theme.dart';

/// ASR-229 · D4 件 2/3 + ASR-234：一个自定义包的详情 + 六步学习入口 + 卸载级联。
///
/// 口径写死在这里，避免超实装（第五颗雷）：
///  1. 这些块和官方模块走**同一套六步学习闭环**（锚定→拆解→听辨→跟读→替换→开口），
///     学完进 1/3/7/14 天复习；以「非完整关卡」会话接入 PracticeLoop，写入只落 `user:` 行，
///     官方已掌握/复习排期/断点一律不碰（库层 kUserKeyExclude + 非锚定会话不写 resume kv）；
///  2. 删除是级联的：档案 + 该包的台账行（含学习进度）一起清，官方模块与其他自定义包不动。
class UserPackageDetailScreen extends StatefulWidget {
  const UserPackageDetailScreen({super.key, required this.moduleKey});

  final String moduleKey;

  /// ASR-234：以「非完整关卡」会话接入同一套六步 PracticeLoop。
  /// chunks != null ⇒ 不走官方审计/自愈/断点 kv，写入只落 `user:` 行。
  /// review=false 走完整六步（从首个未掌握块续学）；review=true 走后四步复习。
  ///
  /// 静态方法供「词块库 · 我的模块」等入口复用，保证六步入口只有一个实现。
  static Future<void> openPractice(
    BuildContext context,
    UserPackageRecord rec, {
    bool review = false,
  }) async {
    if (rec.entries.isEmpty) return;
    final level = PracticeSession.userModuleLevel(rec);
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (routeCtx) => Scaffold(
        appBar: AppBar(
            title: Text(review ? '复习 · ${rec.moduleName}' : '学习 · ${rec.moduleName}')),
        body: PracticeLoop(
          level: level,
          chunks: level.chunks,
          reviewMode: review,
          onDone: (_) => Navigator.of(routeCtx).maybePop(),
        ),
      ),
    ));
  }

  @override
  State<UserPackageDetailScreen> createState() => _UserPackageDetailScreenState();
}

class _UserPackageDetailScreenState extends State<UserPackageDetailScreen> {
  UserPackageRecord? _rec;
  bool _loaded = false;

  /// 本包各块的台账行（只读 `user:` 命名空间），供进度摘要与每条状态徽标。
  Map<String, ChunkRow> _rows = const {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final progress = Provider.of<ProgressService>(context, listen: false);
    final store = UserPackageStore(progress.database);
    final rec = await store.packageOf(widget.moduleKey);
    // 只取本包声明的键；allUserChunks 是 user 专属读路径，不碰官方台账。
    final userRows = await progress.database.allUserChunks();
    final keys = {for (final e in rec?.entries ?? const <UserChunkEntry>[]) e.chunkKey};
    final rows = {
      for (final r in userRows)
        if (keys.contains(r.chunkKey)) r.chunkKey: r,
    };
    if (!mounted) return;
    setState(() {
      _rec = rec;
      _rows = rows;
      _loaded = true;
    });
  }

  ChunkAssetState _stateOf(UserChunkEntry e) =>
      _rows[e.chunkKey]?.assetState ?? ChunkAssetState.learning;

  Widget _stateBadge(ChunkAssetState s) {
    final (label, color) = switch (s) {
      ChunkAssetState.learning => ('没学过', kTextFaint),
      ChunkAssetState.consolidating => ('正在练', kInfo),
      ChunkAssetState.consolidated => ('练熟了', kPrimary),
      ChunkAssetState.longTerm => ('长期记忆', kUnlocked),
      ChunkAssetState.mastered => ('学会了', kUnlocked),
      ChunkAssetState.relearning => ('再练练', kError),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.45)),
      ),
      child: Text(label,
          style: TextStyle(color: color, fontSize: 10, fontWeight: FontWeight.w600)),
    );
  }

  int get _masteredCount => _rec?.entries
          .where((e) => _stateOf(e) == ChunkAssetState.mastered)
          .length ??
      0;

  bool get _hasStarted =>
      _rec?.entries.any((e) => _stateOf(e) != ChunkAssetState.learning) ?? false;

  /// ASR-234：以「非完整关卡」会话接入同一套六步 PracticeLoop。
  /// chunks != null ⇒ 不走官方审计/自愈/断点 kv，写入只落 `user:` 行。
  /// review=false 走完整六步（从首个未掌握块续学）；review=true 走后四步复习。
  Future<void> _learn({required bool review}) async {
    final rec = _rec;
    if (rec == null) return;
    await UserPackageDetailScreen.openPractice(context, rec, review: review);
    if (mounted) _load();
  }

  Future<void> _delete() async {
    final rec = _rec;
    if (rec == null) return;
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: kCard,
        title: Text('删掉「${rec.moduleName}」？',
            style: TextStyle(color: kText, fontSize: 17)),
        content: Text(
          '会一起删掉：\n'
          '· 这本里的 ${rec.chunkCount} 句\n'
          '· 这些句子学过的记录\n\n'
          '不会动：官方内容和学习记录，以及别的小本子。\n'
          '想再学，把内容重新粘一次就行。',
          style: TextStyle(color: kTextSecondary, fontSize: 13, height: 1.5)),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: Text('取消', style: TextStyle(color: kTextMuted))),
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('删掉',
                  style: TextStyle(color: Colors.redAccent))),
        ],
      ),
    );
    if (yes != true || !mounted) return;
    final store =
        UserPackageStore(Provider.of<ProgressService>(context, listen: false).database);
    final removed = await store.removePackage(rec.moduleKey);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('已删掉「${rec.moduleName}」'
            '${removed > 0 ? '，连同 $removed 条学习记录' : ''}。'),
        duration: const Duration(seconds: 2)));
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final rec = _rec;
    return Scaffold(
      appBar: AppBar(title: Text(rec?.moduleName ?? '我的英语本')),
      body: !_loaded
          ? const Center(child: CircularProgressIndicator())
          : rec == null
              ? Center(
                  child: Text('这本已经找不到了。',
                      style: TextStyle(color: kTextMuted)))
              : ListView(
                  padding: const EdgeInsets.all(20),
                  children: [
                    Text('共 ${rec.chunkCount} 句',
                        style: TextStyle(
                            color: kText,
                            fontSize: 17,
                            fontWeight: FontWeight.w700)),
                    const SizedBox(height: 6),
                    Text('存于 '
                        '${DateTime.fromMillisecondsSinceEpoch(rec.importedAt).toString().substring(0, 16)}',
                        style: TextStyle(color: kTextFaint, fontSize: 12)),
                    const SizedBox(height: 10),
                    Text('这些句子和官方内容用同一套练习：先听懂，再拆开，'
                        '跟着读、换着说，最后自己说出来。学完会按 1/3/7/14 天提醒你复习。'
                        '学习记录只记在这本里，官方进度不变。',
                        style: TextStyle(color: kTextMuted, fontSize: 12, height: 1.5)),
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                          color: kCard, borderRadius: BorderRadius.circular(10)),
                      child: Row(
                        children: [
                          Icon(Icons.school, color: kPrimary, size: 20),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                                '已经学会 $_masteredCount / ${rec.chunkCount} 句'
                                '${_hasStarted ? ' · 会按时提醒你复习' : ' · 还没开始学'}',
                                style: TextStyle(color: kText, fontSize: 13)),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: FilledButton.icon(
                            key: const Key('userpkg_learn'),
                            onPressed: () => _learn(review: false),
                            icon: Icon(Icons.play_arrow, color: kOnPrimary, size: 20),
                            label: Text(_hasStarted ? '继续学' : '开始学',
                                style: TextStyle(color: kOnPrimary, fontSize: 14)),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: OutlinedButton.icon(
                            key: const Key('userpkg_review'),
                            onPressed: _hasStarted ? () => _learn(review: true) : null,
                            icon: Icon(Icons.replay,
                                color: _hasStarted ? kPrimary : kTextFaint, size: 18),
                            label: Text('复习这本',
                                style: TextStyle(
                                    color: _hasStarted ? kPrimary : kTextFaint,
                                    fontSize: 14)),
                          ),
                        ),
                      ],
                    ),
                    if (!_hasStarted)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text('先学一遍，复习按钮才会亮。',
                            style: TextStyle(color: kTextFaint, fontSize: 11)),
                      ),
                    const SizedBox(height: 14),
                    for (final e in rec.entries)
                      Container(
                        margin: const EdgeInsets.only(bottom: 8),
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                            color: kCard,
                            borderRadius: BorderRadius.circular(10)),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: Text(e.front,
                                      style: TextStyle(
                                          color: kText,
                                          fontSize: 15,
                                          fontWeight: FontWeight.w700)),
                                ),
                                const SizedBox(width: 8),
                                _stateBadge(_stateOf(e)),
                              ],
                            ),
                            const SizedBox(height: 2),
                            if (e.back.trim().isNotEmpty)
                              Text(e.back,
                                  style: TextStyle(
                                      color: kTextSecondary, fontSize: 13)),
                            if ((e.phonetic ?? '').isNotEmpty)
                              Padding(
                                padding: const EdgeInsets.only(top: 2),
                                child: Text('/${e.phonetic}/',
                                    style: TextStyle(
                                        color: kTextFaint, fontSize: 12)),
                              ),
                            if ((e.example ?? '').isNotEmpty)
                              Padding(
                                padding: const EdgeInsets.only(top: 4),
                                child: Text(e.example!,
                                    style: TextStyle(
                                        color: kTextMuted, fontSize: 12)),
                              ),
                            if (e.tags.isNotEmpty)
                              Padding(
                                padding: const EdgeInsets.only(top: 4),
                                child: Text(
                                    e.tags.map((t) => '#$t').join(' · '),
                                    style: TextStyle(
                                        color: kTextFaint, fontSize: 11)),
                              ),
                          ],
                        ),
                      ),
                    const SizedBox(height: 10),
                    OutlinedButton(
                        onPressed: _delete,
                        child: const Text('删掉这本',
                            style: TextStyle(color: Colors.redAccent))),
                    const SizedBox(height: 6),
                    Text('手机上最多 $kUserPackageMaxPackages 本、每本最多 '
                        '$kUserPackageMaxChunks 句；删掉一本才能再存新的。',
                        style: TextStyle(color: kTextFaint, fontSize: 12)),
                  ],
            ),
    );
  }
}
