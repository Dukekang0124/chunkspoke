import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../app/session.dart';
import '../ui/theme.dart';

class NavItem {
  final String path;
  final String label;
  final IconData icon;
  const NavItem(this.path, this.label, this.icon);
}

const List<NavItem> kNavItems = [
  NavItem('/', '门户', Icons.home_outlined),
  NavItem('/library', '词块库', Icons.table_chart_outlined),
  NavItem('/articles', '阅读', Icons.menu_book_outlined),
  NavItem('/review', '复习', Icons.style_outlined),
  NavItem('/data', '数据', Icons.storage_outlined),
];

class AppWebShell extends StatelessWidget {
  const AppWebShell({
    super.key,
    required this.session,
    required this.location,
    required this.child,
  });

  final AppSession session;
  final String location;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final narrow = MediaQuery.sizeOf(context).width < 768;
    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            const Text('ChunkSpoke'),
            const SizedBox(width: 10),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: kPrimary.withValues(alpha: 0.16),
                borderRadius: BorderRadius.circular(999),
              ),
              child: const Text(
                '网页版 Beta',
                style: TextStyle(color: kPrimary, fontSize: 11, fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ),
        actions: [
          ValueListenableBuilder<int>(
            valueListenable: session.reviewedToday,
            builder: (context, n, _) => Container(
              margin: const EdgeInsets.only(right: 16),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: kCard,
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                '今日已复习 $n 块',
                style: const TextStyle(color: Colors.white70, fontSize: 13),
              ),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          if (narrow)
            Container(
              width: double.infinity,
              color: kCard,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: const Text(
                '当前窗口较窄，建议在电脑上使用网页版，或使用 App。',
                style: TextStyle(color: Colors.white70, fontSize: 12),
              ),
            ),
          Container(
            decoration: const BoxDecoration(
              border: Border(bottom: BorderSide(color: kLocked, width: 0.5)),
            ),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (final item in kNavItems)
                    _NavButton(item: item, selected: _isSelected(item.path)),
                ],
              ),
            ),
          ),
          Expanded(child: child),
        ],
      ),
    );
  }

  bool _isSelected(String path) =>
      path == '/' ? location == '/' : location.startsWith(path);
}

class _NavButton extends StatelessWidget {
  const _NavButton({required this.item, required this.selected});

  final NavItem item;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () => context.go(item.path),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: selected ? kPrimary : Colors.transparent,
              width: 2,
            ),
          ),
        ),
        child: Row(
          children: [
            Icon(item.icon, size: 18, color: selected ? kPrimary : Colors.white60),
            const SizedBox(width: 6),
            Text(
              item.label,
              style: TextStyle(
                color: selected ? Colors.white : Colors.white60,
                fontSize: 14,
                fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
