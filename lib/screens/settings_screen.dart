import 'package:flutter/material.dart';

import '../ui/theme.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(24),
      children: const [
        Text(
          '设置',
          style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Colors.white),
        ),
        SizedBox(height: 16),
        _InfoRow(label: '网页版版本', value: '0.9.0-web（预置骨架）'),
        _InfoRow(label: '内容包', value: '尚未接入'),
        _InfoRow(label: '数据位置', value: '本机浏览器（IndexedDB）'),
        _InfoRow(label: 'App 专属项', value: '语音识别、整句发音、AI 造句'),
      ],
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: kCard,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: kLocked),
      ),
      child: Row(
        children: [
          Text(label, style: const TextStyle(color: Colors.white60, fontSize: 13)),
          const Spacer(),
          Text(value, style: const TextStyle(color: Colors.white, fontSize: 13)),
        ],
      ),
    );
  }
}
