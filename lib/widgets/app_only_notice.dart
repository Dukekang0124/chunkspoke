import 'package:flutter/material.dart';

import '../ui/theme.dart';

class AppOnlyNotice extends StatelessWidget {
  const AppOnlyNotice({super.key, this.compact = false});

  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 12, vertical: compact ? 8 : 12),
      decoration: BoxDecoration(
        color: kCard,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: kLocked),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.phone_android, size: 16, color: kPrimary),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              '语音与 AI 功能请使用 App',
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.75),
                fontSize: compact ? 12 : 13,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
