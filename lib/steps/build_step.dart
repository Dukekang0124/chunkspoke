import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/content_pack.dart';
import '../services/crash_log.dart';
import '../services/loaders.dart';
import '../services/state_machine.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';
import '../ui/feedback.dart';
import '../ui/motion.dart';

/// ③ 块拼句（核心差异化环节）：给出目标句的「中文提示」，把打乱的「词块卡片」
/// 拖进槽位拼出句子。卡片 = 正确词块 + 少量干扰卡（≤2）；正确块之间可点击互换微调。
class BuildStep extends StatefulWidget {
  final Level level;
  final Chunk chunk; // 当前正在练的词块（用于进度/文案）
  final TargetSentence sentence; // 本环节要拼的目标句（含 chunkIds）
  final VoidCallback onDone;
  const BuildStep(
      {required this.level,
      required this.chunk,
      required this.sentence,
      required this.onDone,
      super.key});

  @override
  State<BuildStep> createState() => _BuildStepState();
}

class _BuildStepState extends State<BuildStep>
    with SingleTickerProviderStateMixin {
  late final List<String> _expected; // 按 chunkIds 顺序展开的目标词块文本
  late final List<String?> _filled;
  late final List<String> _tray; // 可拖拽的词块卡片（正确块 + ≤2 干扰块）
  late final Map<String, String> _typeOf; // 文本 → 类型
  bool _built = false;
  bool _revealEn = false;
  int _selected = -1; // 已落槽块中“被选中待互换”的索引
  // B2：错误抖动 + 红闪
  late final AnimationController _shakeCtrl;

  @override
  void initState() {
    super.initState();
    _shakeCtrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 350));
    final byId = {for (final c in widget.level.chunks) c.id: c};
    _expected = widget.sentence.orderedChunkTexts(byId);
    _filled = List<String?>.filled(_expected.length, null);
    _typeOf = {for (final c in widget.level.chunks) c.text: c.type};

    final distractors = widget.level.chunks
        .where((c) => !_expected.contains(c.text))
        .map((c) => c.text)
        .toList()
      ..shuffle();
    _tray = [..._expected];
    for (final d in distractors.take(2)) {
      _tray.add(d);
    }
    _tray.shuffle();
  }

  String _typeFor(String t) => _typeOf[t] ?? 'content';

  void _place(int i, String tile) {
    if (tile != _expected[i] || _filled[i] != null) return; // 顺序/类型错误 → 回弹
    Motion.of(context).tap();
    setState(() {
      _filled[i] = tile;
      _tray.remove(tile);
      _selected = -1;
    });
    if (assemblyCorrect(_filled, _expected)) {
      setState(() => _built = true);
      chimeCorrect(context);
      Provider.of<TtsService>(context, listen: false)
          .speak(widget.sentence.text);
      Future.delayed(const Duration(milliseconds: 700), () {
        if (mounted) widget.onDone();
      });
    }
  }

  /// 已落槽块之间点击互换（微调顺序）：先点一个选中，再点另一个交换。
  void _tapSlot(int i) {
    if (_filled[i] == null) return;
    if (_selected == -1) {
      setState(() => _selected = i);
    } else if (_selected == i) {
      setState(() => _selected = -1);
    } else {
      setState(() {
        final tmp = _filled[_selected];
        _filled[_selected] = _filled[i];
        _filled[i] = tmp;
        _selected = -1;
      });
    }
  }

  void _recordWrong() {
    if (mounted && Motion.of(context).animates) {
      _shakeCtrl.forward(from: 0); // B2 错误抖动（降级时只变红不摇）
    }
    final store =
        Provider.of<ProgressService>(context, listen: false).chunkStore;
    store.applyEvent(widget.chunk.id, ChunkEvent.dragWrong).catchError((e, st) {
      CrashLog.write('Build.dragWrong: $e', st);
    });
  }

  @override
  void dispose() {
    _shakeCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        children: [
          SceneCard(widget.level.theme),
          const SizedBox(height: 16),
          const Text('用中文意思，把「词块」拖进槽位拼出句子',
              style: TextStyle(
                  color: kPrimary, fontSize: 15, fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              color: kBg.withValues(alpha: 0.5),
              border: Border.all(color: Colors.white24),
            ),
            child: Text(
              _revealEn || _built
                  ? widget.sentence.text
                  : widget.sentence.meaningCN,
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.w600),
            ),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              TextButton(
                onPressed: () => setState(() => _revealEn = !_revealEn),
                child: Text(_revealEn || _built ? '隐藏英文' : '看英文',
                    style: const TextStyle(color: kPrimary)),
              ),
              TextButton(
                onPressed: () => speakOrHint(
                    context,
                    Provider.of<TtsService>(context, listen: false),
                    widget.sentence.text),
                child: const Text('🔊 听句子', style: TextStyle(color: kPrimary)),
              ),
            ],
          ),
          const SizedBox(height: 12),
          AnimatedBuilder(
            animation: _shakeCtrl,
            builder: (ctx, _) {
              final s = _shakeCtrl.value;
              final shaking = s > 0 && s < 1;
              final dx =
                  shaking ? math.sin(s * math.pi * 6) * 8 * (1 - s) : 0.0;
              return Transform.translate(
                offset: Offset(dx, 0),
                child: Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: shaking
                          ? Colors.redAccent
                          : (_built ? kUnlocked : Colors.white24),
                      width: 2,
                    ),
                    color: shaking
                        ? Colors.redAccent.withValues(alpha: 0.12)
                        : (_built
                            ? kUnlocked.withValues(alpha: 0.08)
                            : Colors.transparent),
                    boxShadow: _built
                        ? [
                            BoxShadow(
                                color: kUnlocked.withValues(alpha: 0.4),
                                blurRadius: 14)
                          ]
                        : null,
                  ),
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    alignment: WrapAlignment.center,
                    children: List.generate(_expected.length, (i) {
                      return DragTarget<String>(
                        builder: (ctx, cand, rej) => GestureDetector(
                          onTap: () => _tapSlot(i),
                          // B2 磁吸：落槽瞬间 150ms 弹性缩放入位
                          child: AnimatedScale(
                            scale: _filled[i] != null ? 1.0 : 0.85,
                            duration: Motion.of(ctx).dur(150),
                            curve: const Cubic(0.34, 1.56, 0.64, 1),
                            child: _filled[i] != null
                                ? Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 14, vertical: 10),
                                    decoration: BoxDecoration(
                                      borderRadius: BorderRadius.circular(10),
                                      border: Border.all(
                                        color: _selected == i
                                            ? kPrimary
                                            : Colors.white24,
                                        width: _selected == i ? 2 : 1,
                                      ),
                                    ),
                                    child: ChunkTile(
                                        _filled[i]!, _typeFor(_filled[i]!)),
                                  )
                                : Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 14, vertical: 10),
                                    decoration: BoxDecoration(
                                      borderRadius: BorderRadius.circular(10),
                                      border: Border.all(
                                        color: _selected == i
                                            ? kPrimary
                                            : Colors.white24,
                                        width: _selected == i ? 2 : 1,
                                      ),
                                    ),
                                    child: const Text('—',
                                        style: TextStyle(
                                            color: Colors.white24,
                                            fontSize: 16)),
                                  ),
                          ),
                        ),
                        onWillAcceptWithDetails: (details) =>
                            details.data == _expected[i] && _filled[i] == null,
                        onAcceptWithDetails: (details) =>
                            _place(i, details.data),
                      );
                    }),
                  ),
                ),
              );
            },
          ),
          if (_built)
            const Padding(
              padding: EdgeInsets.only(top: 12),
              child: Text('句子拼好了！现在说出来',
                  style: TextStyle(
                      color: kUnlocked,
                      fontSize: 16,
                      fontWeight: FontWeight.w600)),
            ),
          const Spacer(),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            alignment: WrapAlignment.center,
            children: _tray
                .map((t) => Draggable<String>(
                      data: t,
                      feedback: ChunkTile(t, _typeFor(t)),
                      childWhenDragging: Opacity(
                        opacity: 0.3,
                        child: ChunkTile(t, _typeFor(t)),
                      ),
                      onDragEnd: (d) {
                        if (!d.wasAccepted) _recordWrong();
                      },
                      child: ChunkTile(t, _typeFor(t), interactive: true),
                    ))
                .toList(),
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }
}
