import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../ui/theme.dart';
import '../widgets/app_only_notice.dart';

class PortalScreen extends StatelessWidget {
  const PortalScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return ListView(
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
        const SizedBox(height: 24),
        LayoutBuilder(
          builder: (context, constraints) {
            final columns = constraints.maxWidth >= 1024 ? 3 : (constraints.maxWidth >= 768 ? 2 : 1);
            return GridView.count(
              crossAxisCount: columns,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              mainAxisSpacing: 16,
              crossAxisSpacing: 16,
              childAspectRatio: 2.4,
              children: const [
                _CapabilityCard(
                  title: '词块库',
                  body: '五列表格：块 / 中文 / 层级 / 频次排名 / 掌握状态。',
                  path: '/library',
                  icon: Icons.table_chart_outlined,
                ),
                _CapabilityCard(
                  title: '沉浸阅读',
                  body: '文章与词块面板并排，句级高亮对照。',
                  path: '/articles',
                  icon: Icons.menu_book_outlined,
                ),
                _CapabilityCard(
                  title: '复习台',
                  body: '卡片流 + 键盘流：空格翻面，1-3 自评，Enter 下一个。',
                  path: '/review',
                  icon: Icons.style_outlined,
                ),
                _CapabilityCard(
                  title: '数据',
                  body: '本机导出与导入，文件不出浏览器。',
                  path: '/data',
                  icon: Icons.storage_outlined,
                ),
              ],
            );
          },
        ),
        const SizedBox(height: 24),
        const Text(
          '点击卡片进入对应页面。内容包与复习队列将在正式开工后接入。',
          style: TextStyle(color: Colors.white38, fontSize: 12),
        ),
      ],
    );
  }
}

class _CapabilityCard extends StatelessWidget {
  const _CapabilityCard({
    required this.title,
    required this.body,
    required this.path,
    required this.icon,
  });

  final String title;
  final String body;
  final String path;
  final IconData icon;

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
          children: [
            Icon(icon, color: kPrimary, size: 22),
            const SizedBox(height: 10),
            Text(
              title,
              style: const TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 6),
            Expanded(
              child: Text(
                body,
                style: const TextStyle(color: Colors.white60, fontSize: 13, height: 1.5),
                overflow: TextOverflow.fade,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
