import 'package:flutter/material.dart';
import '../models/content_pack.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';
import 'say_widget.dart';

/// SWAP 步骤：高亮可替换槽 → 选替换词 → 组成新句 → 亲口说出（L3）。
class SwapStep extends StatefulWidget {
  final Chunk chunk;
  final String levelId;
  final VoidCallback onDone;
  const SwapStep(
      {required this.chunk,
      required this.levelId,
      required this.onDone,
      super.key});

  @override
  State<SwapStep> createState() => _SwapStepState();
}

class _SwapStepState extends State<SwapStep> {
  bool _saying = false;
  String? _chosen;
  late final List<Slot> _slots;
  late final int _swapIndex;

  @override
  void initState() {
    super.initState();
    _slots = widget.chunk.sentence.slots;
    _swapIndex = widget.chunk.sentence.swapSlotIndex;
  }

  String _newSentence(String option) {
    final parts = _slots.map((s) => s.text).toList();
    parts[_swapIndex] = option;
    return parts.join(' ');
  }

  Future<void> _confirmSkip(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: kCard,
        title: Text('跳过本题？', style: TextStyle(color: kText)),
        content: Text('跳过替换练习，本题不计入掌握度。',
            style: TextStyle(color: kTextSecondary)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text('取消', style: TextStyle(color: kTextMuted)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text('确定跳过', style: TextStyle(color: kPrimary)),
          ),
        ],
      ),
    );
    if (ok == true) widget.onDone();
  }

  @override
  Widget build(BuildContext context) {
    if (_saying && _chosen != null) {
      return SayWidget(
          sentence: _newSentence(_chosen!),
          levelId: widget.levelId,
          onDone: (_) => widget.onDone);
    }
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        children: [
          const SizedBox(height: 8),
          Text('替换其中一部分', style: TextStyle(color: kTextSecondary)),
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            alignment: WrapAlignment.center,
            children: List.generate(_slots.length, (i) {
              final s = _slots[i];
              final highlight = i == _swapIndex;
              return Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: highlight ? kPrimary : kBorderStrong,
                    width: highlight ? 2 : 1,
                  ),
                  color: highlight
                      ? kPrimary.withValues(alpha: 0.12)
                      : Colors.transparent,
                ),
                child: Text(s.text,
                    style: TextStyle(
                        color: highlight ? kPrimary : kText,
                        fontSize: 16,
                        fontWeight:
                            highlight ? FontWeight.bold : FontWeight.normal)),
              );
            }),
          ),
          const SizedBox(height: 24),
          Text('选择一个替换词', style: TextStyle(color: kTextSecondary)),
          const SizedBox(height: 12),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            alignment: WrapAlignment.center,
            children: widget.chunk.sentence.swapOptions.map((opt) {
              return GestureDetector(
                onTap: () => setState(() {
                  _chosen = opt;
                  _saying = true;
                }),
                child: ChunkTile(opt, 'content', interactive: true),
              );
            }).toList(),
          ),
          const Spacer(),
          TextButton(
            onPressed: () => _confirmSkip(context),
            child: Text('跳过', style: TextStyle(color: kTextFaint)),
          ),
          const SizedBox(height: 12),
        ],
      ),
    );
  }
}
