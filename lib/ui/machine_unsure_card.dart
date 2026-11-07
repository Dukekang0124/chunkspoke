import 'package:flutter/material.dart';

import 'theme.dart';

/// ASR-229 D4 件 4 的卡片本体；ASR-233 抽成共享组件，第 4/5/6 步用同一张卡。
///
/// 判据单源仍是 `l4_step.dart::machineUncertain()`（本文件不含任何阈值、不做判定），
/// 这里只负责把「机器自己没底」说出口，并给一条一级自证按钮。
/// 文案红线：明写「不计发音分」，不承诺没实装的记账，也不给判定后门。
class MachineUnsureCard extends StatelessWidget {
  const MachineUnsureCard({
    required this.why,
    required this.onAttest,
    this.note = _defaultNote,
    super.key,
  });

  /// 为什么机器没把握（由调用方按自己的判定层结论组装，不含阈值）。
  final String why;

  /// 自证出口；null = 按钮禁用（例如还没有任何录音可认）。
  final VoidCallback? onAttest;

  /// 记账口径说明：各步落的账不同，调用方必须给自己的真实口径。
  final String note;

  static const String _defaultNote =
      '这一步按「你自己确认」通过，不记发音分；是否算掌握仍走原有门槛'
      '（前面步骤一次通过 + 星级），本页没改任何判定阈值。';

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('machineUnsureCard'),
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: kCard,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: kPrimary.withValues(alpha: 0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('这台机器没把握，不是给你判错',
              style: TextStyle(
                  color: kPrimary, fontSize: 14, fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          Text(why,
              style: TextStyle(color: kTextSecondary, fontSize: 12, height: 1.5)),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              style: FilledButton.styleFrom(backgroundColor: kUnlocked),
              onPressed: onAttest,
              child: Text('就是这句，算我说过（不计发音分）',
                  style: TextStyle(color: kText, fontSize: 14)),
            ),
          ),
          const SizedBox(height: 6),
          Text(note,
              style: TextStyle(color: kTextFaint, fontSize: 11, height: 1.4)),
        ],
      ),
    );
  }
}