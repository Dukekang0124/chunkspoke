import 'package:flutter/material.dart';

import 'theme.dart';

/// 应用内错误页（P0 加固）：任何页面异常都不允许灰屏/闪退退桌面，
/// 统一渲染本页：明确报错 + 可重试，错误细节可展开。
class ErrorBody extends StatelessWidget {
  final Object? detail;
  final VoidCallback? onRetry;
  const ErrorBody({this.detail, this.onRetry, super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: kBg,
      width: double.infinity,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, color: kPrimary, size: 44),
              const SizedBox(height: 12),
              const Text('出了点问题',
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.w600)),
              const SizedBox(height: 6),
              const Text('已记录错误信息，点击重试或反馈给我们',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white54, fontSize: 13)),
              if (detail != null) ...[
                const SizedBox(height: 12),
                Text('$detail',
                    maxLines: 6,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white24, fontSize: 11)),
              ],
              if (onRetry != null) ...[
                const SizedBox(height: 18),
                ElevatedButton(
                  style:
                      ElevatedButton.styleFrom(backgroundColor: kPrimary),
                  onPressed: onRetry,
                  child:
                      const Text('重试', style: TextStyle(color: Colors.white)),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
