import 'package:flutter/material.dart';

import '../ui/theme.dart';
import '../widgets/app_only_notice.dart';

class LibraryScreen extends StatelessWidget {
  const LibraryScreen({super.key});

  static const List<String> _columns = ['块', '中文', '层级', '频次排名', '掌握状态'];

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text(
                '词块库',
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Colors.white),
              ),
              const Spacer(),
              const AppOnlyNotice(compact: true),
            ],
          ),
          const SizedBox(height: 16),
          Container(
            decoration: BoxDecoration(
              color: kCard,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: kLocked),
            ),
            child: Column(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  decoration: const BoxDecoration(
                    border: Border(bottom: BorderSide(color: kLocked, width: 0.5)),
                  ),
                  child: Row(
                    children: [
                      for (final c in _columns)
                        Expanded(
                          flex: c == '块' ? 3 : 2,
                          child: Text(
                            c,
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 16, vertical: 40),
                  child: Text(
                    '内容包尚未接入：本页在正式开工后接入核心词块库与筛选。',
                    style: TextStyle(color: Colors.white54, fontSize: 13),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
