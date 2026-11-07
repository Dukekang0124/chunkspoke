import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/loaders.dart';
import '../services/user_package.dart';
import '../services/user_package_store.dart';
import '../ui/theme.dart';

/// ASR-229 · D4 件 2/3：一个自定义包的只读详情 + 卸载级联。
///
/// 两条口径写死在这里，避免超实装（第五颗雷）：
///  1. 这些块**目前还不能**像官方模块那样走六步学习与复习排期——接入学习管线是下一步的事，
///     本页只负责「你导进来的东西看得见、管得住」；
///  2. 删除是级联的：档案 + 该包的台账行一起清，官方模块的已掌握/复习/断点一律不碰。
class UserPackageDetailScreen extends StatefulWidget {
  const UserPackageDetailScreen({super.key, required this.moduleKey});

  final String moduleKey;

  @override
  State<UserPackageDetailScreen> createState() => _UserPackageDetailScreenState();
}

class _UserPackageDetailScreenState extends State<UserPackageDetailScreen> {
  UserPackageRecord? _rec;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final store = UserPackageStore(
        Provider.of<ProgressService>(context, listen: false).database);
    final rec = await store.packageOf(widget.moduleKey);
    if (!mounted) return;
    setState(() {
      _rec = rec;
      _loaded = true;
    });
  }

  Future<void> _delete() async {
    final rec = _rec;
    if (rec == null) return;
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: kCard,
        title: Text('删除「${rec.moduleName}」？',
            style: TextStyle(color: kText, fontSize: 17)),
        content: Text(
          '会一起清掉：\n'
          '· 这个包的档案（${rec.chunkCount} 块的定义）\n'
          '· 台账里属于它的行（如果将来接入学习后的进度，也一并清）\n\n'
          '不会动：官方模块的已掌握数、复习排期、断点，以及其他自定义包。\n'
          '同一份表随时可以再导回来（块 ID 由内容决定，重导是整包替换）。',
          style: TextStyle(color: kTextSecondary, fontSize: 13, height: 1.5)),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: Text('取消', style: TextStyle(color: kTextMuted))),
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('确认删除',
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
        content: Text('已删除「${rec.moduleName}」（清掉 $removed 行台账 + 1 份档案）'),
        duration: const Duration(seconds: 2)));
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final rec = _rec;
    return Scaffold(
      appBar: AppBar(title: Text(rec?.moduleName ?? '我的模块')),
      body: !_loaded
          ? const Center(child: CircularProgressIndicator())
          : rec == null
              ? Center(
                  child: Text('这个档案已经不在了。',
                      style: TextStyle(color: kTextMuted)))
              : ListView(
                  padding: const EdgeInsets.all(20),
                  children: [
                    Text('${rec.chunkCount} 块 · ${rec.moduleName}',
                        style: TextStyle(
                            color: kText,
                            fontSize: 17,
                            fontWeight: FontWeight.w700)),
                    const SizedBox(height: 6),
                    Text('导入时间：'
                        '${DateTime.fromMillisecondsSinceEpoch(rec.importedAt).toString().substring(0, 19)}',
                        style: TextStyle(color: kTextFaint, fontSize: 12)),
                    const SizedBox(height: 10),
                    Text('这些块现在能看、能管，但还不能像官方模块那样走六步学习；'
                        '学习管线接入是下一步的事，这里不提前承诺。',
                        style: TextStyle(color: kTextMuted, fontSize: 12, height: 1.5)),
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
                            Text(e.front,
                                style: TextStyle(
                                    color: kText,
                                    fontSize: 15,
                                    fontWeight: FontWeight.w700)),
                            const SizedBox(height: 2),
                            Text(e.back,
                                style: TextStyle(color: kTextSecondary, fontSize: 13)),
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
                            if ((e.cefr ?? '').isNotEmpty || e.tags.isNotEmpty)
                              Padding(
                                padding: const EdgeInsets.only(top: 4),
                                child: Text(
                                    [
                                      if ((e.cefr ?? '').isNotEmpty) e.cefr!,
                                      ...e.tags.map((t) => '#$t'),
                                    ].join(' · '),
                                    style: TextStyle(
                                        color: kTextFaint, fontSize: 11)),
                              ),
                          ],
                        ),
                      ),
                    const SizedBox(height: 10),
                    OutlinedButton(
                        onPressed: _delete,
                        child: const Text('删除这个包（含级联清理）',
                            style: TextStyle(color: Colors.redAccent))),
                    const SizedBox(height: 6),
                    Text('上限提醒：每台设备 $kUserPackageMaxPackages 个包、每包 $kUserPackageMaxChunks 块；'
                        '删掉一个才能再导新的。',
                        style: TextStyle(color: kTextFaint, fontSize: 12)),
                  ],
            ),
    );
  }
}
