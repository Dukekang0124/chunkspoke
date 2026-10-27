import 'package:flutter/material.dart';

import '../app/session.dart';
import '../ui/theme.dart';

class DataScreen extends StatelessWidget {
  const DataScreen({super.key, required this.session});

  final AppSession session;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        const Text(
          '数据',
          style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Colors.white),
        ),
        const SizedBox(height: 8),
        const Text(
          '学习数据存本机浏览器（IndexedDB），文件不出浏览器。',
          style: TextStyle(color: Colors.white70, fontSize: 14),
        ),
        const SizedBox(height: 16),
        ValueListenableBuilder<String?>(
          valueListenable: session.storageError,
          builder: (context, error, _) => Text(
            error == null
                ? '本机存储探测中…'
                : (error.isEmpty ? '本机存储：IndexedDB 可用' : '本机存储不可用：$error'),
            style: TextStyle(
              color: error == null || error.isEmpty ? Colors.white54 : kError,
              fontSize: 12,
            ),
          ),
        ),
        const SizedBox(height: 20),
        _ActionTile(
          title: '导出备份',
          body: '导出为 JSON 交换文件，用于本机备份或迁移。',
          enabled: false,
          actionLabel: '导出',
        ),
        const SizedBox(height: 12),
        _ActionTile(
          title: '导入',
          body: 'App 的 JSON 导出将在 1.5.10 提供；当前只支持导入网页版自己导出的文件。',
          enabled: false,
          actionLabel: '选择文件',
        ),
        const SizedBox(height: 12),
        _ActionTile(
          title: '清空本机学习数据',
          body: '只清除词块进度、统计与事件，不动导入快照与设置。',
          enabled: false,
          actionLabel: '清空',
        ),
        const SizedBox(height: 20),
        const Text(
          '导入/导出/清空在正式开工后接线，当前为只读占位。',
          style: TextStyle(color: Colors.white38, fontSize: 12),
        ),
      ],
    );
  }
}

class _ActionTile extends StatelessWidget {
  const _ActionTile({
    required this.title,
    required this.body,
    required this.enabled,
    required this.actionLabel,
  });

  final String title;
  final String body;
  final bool enabled;
  final String actionLabel;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: kCard,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: kLocked),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  body,
                  style: const TextStyle(color: Colors.white54, fontSize: 13, height: 1.5),
                ),
              ],
            ),
          ),
          const SizedBox(width: 16),
          OutlinedButton(
            onPressed: enabled ? () {} : null,
            style: OutlinedButton.styleFrom(
              foregroundColor: kPrimary,
              side: BorderSide(color: enabled ? kPrimary : kLocked),
            ),
            child: Text(actionLabel),
          ),
        ],
      ),
    );
  }
}
