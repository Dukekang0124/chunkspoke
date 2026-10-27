import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../app/session.dart';
import '../ui/theme.dart';
import '../widgets/app_only_notice.dart';

class PortalScreen extends StatelessWidget {
  const PortalScreen({super.key, required this.session});

  final AppSession session;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: session.revision,
      builder: (context, _, _) => ValueListenableBuilder<bool>(
        valueListenable: session.contentReady,
        builder: (context, ready, _) => ListView(
          padding: const EdgeInsets.all(24),
          children: [
            const Text(
              '在电脑上，继续你的词块复习',
              style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold, color: Colors.white),
            ),
            const SizedBox(height: 8),
            const Text(
              '学习数据存本机浏览器，可导出备份。网页版不录音、不调用 AI。',
              style: TextStyle(color: Colors.white70, fontSize: 14),
            ),
            const SizedBox(height: 20),
            const AppOnlyNotice(),
            const SizedBox(height: 20),
            if (!ready)
              _LoadingCard(session: session)
            else
              _ReadyBody(session: session),
          ],
        ),
      ),
    );
  }
}

class _LoadingCard extends StatelessWidget {
  const _LoadingCard({required this.session});

  final AppSession session;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<String?>(
      valueListenable: session.contentError,
      builder: (context, error, _) {
        if (error != null) {
          return Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: kCard,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: kError),
            ),
            child: Text(
              '内容包加载失败：$error',
              style: const TextStyle(color: kError, fontSize: 13, height: 1.5),
            ),
          );
        }
        return const Padding(
          padding: EdgeInsets.symmetric(vertical: 24),
          child: Row(
            children: [
              SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2, color: kPrimary),
              ),
              SizedBox(width: 10),
              Text('正在加载内容包…', style: TextStyle(color: Colors.white54, fontSize: 13)),
            ],
          ),
        );
      },
    );
  }
}

class _ReadyBody extends StatelessWidget {
  const _ReadyBody({required this.session});

  final AppSession session;

  @override
  Widget build(BuildContext context) {
    final bundle = session.content;
    final rows = session.rows();
    final learned = rows.where((r) => r.record != null).length;
    final mastered = rows.where((r) => r.mastered).length;
    final due = session.dueChunks().length;
    final fresh = session.newChunks().length;

    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = constraints.maxWidth >= 1024 ? 3 : (constraints.maxWidth >= 768 ? 2 : 1);
        final cardWidth =
            (constraints.maxWidth - 16 * (columns - 1)) / columns;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                _Stat(label: '词块库', value: '${bundle?.chunks.length ?? 0} 块'),
                _Stat(label: '已学', value: '$learned 块'),
                _Stat(label: '已掌握', value: '$mastered 块'),
                _Stat(label: '今日已复习', value: '${session.reviewedToday.value} 块'),
              ],
            ),
            const SizedBox(height: 20),
            Wrap(
              spacing: 16,
              runSpacing: 16,
              children: [
                SizedBox(
                  width: cardWidth,
                  child: _CapabilityCard(
                    title: '词块库',
                    body: '五列表格：块 / 中文 / 层级 / 频次排名 / 掌握状态。点一行看详情。',
                    path: '/library',
                    icon: Icons.table_chart_outlined,
                    trailing: '${bundle?.chunks.length ?? 0} 块',
                  ),
                ),
                SizedBox(
                  width: cardWidth,
                  child: _CapabilityCard(
                    title: '沉浸阅读',
                    body: '文章与词块面板并排，句级高亮对照。朗读在 App 内可用。',
                    path: '/articles',
                    icon: Icons.menu_book_outlined,
                    trailing: '${bundle?.articles.length ?? 0} 篇',
                  ),
                ),
                SizedBox(
                  width: cardWidth,
                  child: _CapabilityCard(
                    title: '复习台',
                    body: '空格翻面，1-3 自评，Enter 下一个。今天还有 $due 块到期、$fresh 块新学。',
                    path: '/review',
                    icon: Icons.style_outlined,
                    trailing: due > 0 ? '$due 块到期' : '暂无到期',
                    accent: due > 0,
                  ),
                ),
                SizedBox(
                  width: cardWidth,
                  child: _CapabilityCard(
                    title: '数据',
                    body: '本机导出与导入，文件不出浏览器。清空需二次确认。',
                    path: '/data',
                    icon: Icons.storage_outlined,
                    trailing: '本机',
                  ),
                ),
              ],
            ),
            const SizedBox(height: 24),
            const Text(
              '网页版与 App 进度互通排期中，当前两边数据各自独立。',
              style: TextStyle(color: Colors.white38, fontSize: 12),
            ),
          ],
        );
      },
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(right: 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            value,
            style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 2),
          Text(label, style: const TextStyle(color: Colors.white54, fontSize: 12)),
        ],
      ),
    );
  }
}

class _CapabilityCard extends StatelessWidget {
  const _CapabilityCard({
    required this.title,
    required this.body,
    required this.path,
    required this.icon,
    required this.trailing,
    this.accent = false,
  });

  final String title;
  final String body;
  final String path;
  final IconData icon;
  final String trailing;
  final bool accent;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () => context.go(path),
      borderRadius: BorderRadius.circular(14),
      child: Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: kCard,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: kLocked),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Icon(icon, color: kPrimary, size: 22),
                const Spacer(),
                Text(
                  trailing,
                  style: TextStyle(
                    color: accent ? kPrimary : Colors.white38,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              title,
              style: const TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 6),
            Text(
              body,
              style: const TextStyle(color: Colors.white60, fontSize: 13, height: 1.5),
            ),
          ],
        ),
      ),
    );
  }
}
