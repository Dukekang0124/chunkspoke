import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app/session.dart';
import '../data/content.dart';
import '../data/learning.dart';
import '../data/review_rules.dart';
import '../data/vocab.dart';
import '../ui/theme.dart';

enum _Mode { review, learn }

/// 复习台：到期复习（1-3 自评）与新学（词块认识）两条腿。
/// 键盘：空格翻面 · 1/2/3 自评 · Enter 下一个（新学下 Enter = 已认识）。
class ReviewScreen extends StatefulWidget {
  const ReviewScreen({super.key, required this.session});

  final AppSession session;

  @override
  State<ReviewScreen> createState() => ReviewScreenState();
}

class ReviewScreenState extends State<ReviewScreen> {
  final FocusNode _focus = FocusNode(debugLabel: 'review-keyboard');

  _Mode _mode = _Mode.review;
  List<Chunk> _queue = const [];
  int _index = 0;
  bool _flipped = false;
  ReviewGrade? _grade;
  bool _busy = false;
  String? _hint;
  int _gradedThisVisit = 0;

  @override
  void initState() {
    super.initState();
    _focus.requestFocus();
    _reloadQueue();
    widget.session.revision.addListener(_onDataChanged);
  }

  @override
  void dispose() {
    widget.session.revision.removeListener(_onDataChanged);
    _focus.dispose();
    super.dispose();
  }

  void _onDataChanged() {
    if (mounted) setState(() {});
  }

  void _reloadQueue() {
    final session = widget.session;
    if (session.content == null) {
      _queue = const [];
      _index = 0;
      return;
    }
    _queue = _mode == _Mode.review
        ? [for (final r in session.dueChunks()) if (session.content!.byId[r.id] != null) session.content!.byId[r.id]!]
        : session.newChunks();
    _index = 0;
    _flipped = false;
    _grade = null;
    _hint = null;
  }

  void _switchMode(_Mode mode) {
    setState(() {
      _mode = mode;
      _reloadQueue();
    });
    _focus.requestFocus();
  }

  Chunk? get _current => _index < _queue.length ? _queue[_index] : null;

  void _onKey(KeyEvent event) {
    if (event is! KeyDownEvent || _busy) return;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.space) {
      setState(() => _flipped = !_flipped);
      return;
    }
    if (key == LogicalKeyboardKey.enter || key == LogicalKeyboardKey.numpadEnter) {
      _next();
      return;
    }
    if (_mode != _Mode.review) return;
    if (key == LogicalKeyboardKey.digit1 || key == LogicalKeyboardKey.numpad1) {
      _gradeWith(ReviewGrade.retry);
    } else if (key == LogicalKeyboardKey.digit2 || key == LogicalKeyboardKey.numpad2) {
      _gradeWith(ReviewGrade.keep);
    } else if (key == LogicalKeyboardKey.digit3 || key == LogicalKeyboardKey.numpad3) {
      _gradeWith(ReviewGrade.pass);
    }
  }

  Future<void> _gradeWith(ReviewGrade grade) async {
    final chunk = _current;
    if (chunk == null) return;
    if (_grade != null) {
      setState(() => _hint = '这张已经评过了，按 Enter 看下一个');
      return;
    }
    setState(() {
      _busy = true;
      _hint = null;
    });
    try {
      await widget.session.gradeChunk(chunk, grade);
      if (!mounted) return;
      setState(() {
        _grade = grade;
        _gradedThisVisit += 1;
        _hint = '已记下 · Enter 下一个';
      });
    } catch (e) {
      if (mounted) setState(() => _hint = '保存失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _learnCurrent() async {
    final chunk = _current;
    if (chunk == null) return;
    setState(() {
      _busy = true;
      _hint = null;
    });
    try {
      await widget.session.learnChunk(chunk);
      if (!mounted) return;
      setState(() {
        _gradedThisVisit += 1;
        _index += 1;
        _flipped = false;
        _hint = '已加入复习 · 明天回来复习这一块';
      });
    } catch (e) {
      if (mounted) setState(() => _hint = '保存失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _next() async {
    if (_mode == _Mode.learn) {
      await _learnCurrent();
      return;
    }
    if (_grade == null) {
      setState(() => _hint = '先用 1/2/3 自评，再按 Enter');
      return;
    }
    setState(() {
      _index += 1;
      _flipped = false;
      _grade = null;
      _hint = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final session = widget.session;
    return KeyboardListener(
      focusNode: _focus,
      autofocus: true,
      onKeyEvent: _onKey,
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: ValueListenableBuilder<bool>(
          valueListenable: session.contentReady,
          builder: (context, ready, _) {
            if (!ready) {
              return Center(
                child: ValueListenableBuilder<String?>(
                  valueListenable: session.contentError,
                  builder: (context, err, _) => Text(
                    err == null ? '内容包加载中…' : '内容包加载失败：$err',
                    style: TextStyle(color: err == null ? Colors.white54 : kError),
                  ),
                ),
              );
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _header(session),
                const SizedBox(height: 16),
                if (_current != null)
                  Expanded(child: _card(_current!))
                else if (_mode == _Mode.review && _queue.isEmpty)
                  Expanded(child: _reviewEmpty(session))
                else
                  Expanded(child: _finished()),
                const SizedBox(height: 16),
                _footer(session),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _header(AppSession session) {
    return Row(
      children: [
        const Text(
          '复习台',
          style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Colors.white),
        ),
        const SizedBox(width: 16),
        _ModeTab(
          label: '到期复习',
          count: session.dueChunks().length,
          selected: _mode == _Mode.review,
          onTap: () => _switchMode(_Mode.review),
        ),
        const SizedBox(width: 8),
        _ModeTab(
          label: '新学',
          count: session.newChunks().length,
          selected: _mode == _Mode.learn,
          onTap: () => _switchMode(_Mode.learn),
        ),
        const Spacer(),
        Text(
          '今日已复习 ${session.reviewedToday.value} 块'
          '${_gradedThisVisit > 0 ? ' · 本次 $_gradedThisVisit' : ''}',
          style: const TextStyle(color: Colors.white54, fontSize: 13),
        ),
      ],
    );
  }

  Widget _card(Chunk chunk) {
    final record = widget.session.chunks[chunk.id];
    final mastered = (record?.reviewStage ?? 0) >= kMasteredStage;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 620),
        child: GestureDetector(
          onTap: () => setState(() => _flipped = !_flipped),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.all(28),
            decoration: BoxDecoration(
              color: kCard,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(
                color: _grade == null ? kLocked : _gradeColor(_grade!),
                width: _grade == null ? 1 : 2,
              ),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    _tierBadge(chunk.tier),
                    const SizedBox(width: 8),
                    _badge(chunk.funcCat, Colors.white54),
                    const SizedBox(width: 8),
                    _badge(
                      _mode == _Mode.learn ? '新学' : (record?.assetState.label ?? '未学'),
                      _mode == _Mode.learn ? kPrimary : assetColor(record?.assetState),
                    ),
                    if (mastered) ...[
                      const SizedBox(width: 8),
                      _badge('已掌握', kUnlocked),
                    ],
                  ],
                ),
                const SizedBox(height: 24),
                Text(
                  chunk.text,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 32,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 16),
                if (_flipped) ...[
                  Text(
                    chunk.meaningCN,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: kPrimary, fontSize: 20),
                  ),
                  if (chunk.example.isNotEmpty) ...[
                    const SizedBox(height: 20),
                    Text(
                      chunk.example,
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.white70, fontSize: 15, height: 1.5),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      chunk.exampleCN,
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.white38, fontSize: 13),
                    ),
                  ],
                ] else
                  const Text(
                    '空格翻面看中文',
                    style: TextStyle(color: Colors.white38, fontSize: 13),
                  ),
                const SizedBox(height: 24),
                Text(
                  _queueLabel(chunk),
                  style: const TextStyle(color: Colors.white38, fontSize: 12),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _queueLabel(Chunk chunk) {
    final total = _queue.length;
    if (_mode == _Mode.learn) return '新学 ${_index + 1}/$total · 每日最多 $kDailyNewCap 块';
    final stage = widget.session.chunks[chunk.id]?.reviewStage ?? 0;
    return '到期复习 ${_index + 1}/$total · 本块第 ${stage + 1} 档';
  }

  Widget _reviewEmpty(AppSession session) {
    final rows = session.rows();
    final learned = rows.where((r) => r.state != AssetState.learning).length;
    final capped = session.reviewedToday.value >= kDailyReviewCap;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Container(
          padding: const EdgeInsets.all(28),
          decoration: BoxDecoration(
            color: kCard,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: kLocked),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                capped ? '今天的复习额度用完了（上限 $kDailyReviewCap 块）' : '今天没有到期词块',
                style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 12),
              Text(
                capped
                    ? '明天再回来。也可以去「新学」认识几块新的。'
                    : learned == 0
                        ? '还没有任何词块进入复习周期。先去「新学」认识 1 块，明天它就会到期出现在这里。'
                        : '复习按 1 / 3 / 7 / 14 天阶梯排期；本机已有 $learned 块在周期内。到期后会自动出现在这里。',
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white54, fontSize: 14, height: 1.6),
              ),
              if (!capped) ...[
                const SizedBox(height: 20),
                OutlinedButton(
                  onPressed: () => _switchMode(_Mode.learn),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: kPrimary,
                    side: const BorderSide(color: kPrimary),
                  ),
                  child: const Text('去新学'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _finished() {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Container(
          padding: const EdgeInsets.all(28),
          decoration: BoxDecoration(
            color: kCard,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: kLocked),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                '这一轮清完了',
                style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 10),
              Text(
                _mode == _Mode.learn
                    ? '新学队列已处理完，明天开始复习它们。'
                    : '本次评了 $_gradedThisVisit 块，已完成的下次到期会自动回来。',
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white54, fontSize: 14, height: 1.6),
              ),
              const SizedBox(height: 18),
              OutlinedButton(
                onPressed: () => setState(_reloadQueue),
                style: OutlinedButton.styleFrom(
                  foregroundColor: kPrimary,
                  side: const BorderSide(color: kPrimary),
                ),
                child: const Text('重新载入队列'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _footer(AppSession session) {
    return Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: _mode == _Mode.review
              ? [
                  _GradeChip(
                    label: '1 重学',
                    color: kError,
                    active: _grade == ReviewGrade.retry,
                    onTap: () => _gradeWith(ReviewGrade.retry),
                  ),
                  const SizedBox(width: 12),
                  _GradeChip(
                    label: '2 保留',
                    color: Colors.white70,
                    active: _grade == ReviewGrade.keep,
                    onTap: () => _gradeWith(ReviewGrade.keep),
                  ),
                  const SizedBox(width: 12),
                  _GradeChip(
                    label: '3 通过',
                    color: kUnlocked,
                    active: _grade == ReviewGrade.pass,
                    onTap: () => _gradeWith(ReviewGrade.pass),
                  ),
                  const SizedBox(width: 16),
                  FilledButton(
                    onPressed: _busy ? null : _next,
                    style: FilledButton.styleFrom(backgroundColor: kPrimary, foregroundColor: Colors.black),
                    child: const Text('下一个'),
                  ),
                ]
              : [
                  FilledButton(
                    onPressed: _busy ? null : _learnCurrent,
                    style: FilledButton.styleFrom(backgroundColor: kPrimary, foregroundColor: Colors.black),
                    child: const Text('已认识，加入复习'),
                  ),
                ],
        ),
        const SizedBox(height: 10),
        Text(
          _hint ??
              (_mode == _Mode.review
                  ? '空格翻面 · 1 重学（明天再来）/ 2 保留（明天再来）/ 3 通过（按 1/3/7/14 天升档）· Enter 下一个'
                  : '空格翻面 · Enter 或按钮记为「已认识」· 明天开始复习'),
          textAlign: TextAlign.center,
          style: TextStyle(
            color: _hint == null ? Colors.white38 : kPrimary,
            fontSize: 12,
            height: 1.5,
          ),
        ),
      ],
    );
  }

  Color _gradeColor(ReviewGrade grade) {
    switch (grade) {
      case ReviewGrade.retry:
        return kError;
      case ReviewGrade.keep:
        return Colors.white70;
      case ReviewGrade.pass:
        return kUnlocked;
    }
  }
}

Color assetColor(AssetState? state) {
  switch (state) {
    case null:
    case AssetState.learning:
      return Colors.white54;
    case AssetState.consolidating:
      return kPrimary;
    case AssetState.consolidated:
      return const Color(0xFF6FA8FF);
    case AssetState.longTerm:
      return const Color(0xFFB98CFF);
    case AssetState.mastered:
      return kUnlocked;
    case AssetState.relearning:
      return kError;
  }
}

class _ModeTab extends StatelessWidget {
  const _ModeTab({
    required this.label,
    required this.count,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final int count;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(999),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        decoration: BoxDecoration(
          color: selected ? kPrimary.withValues(alpha: 0.16) : Colors.transparent,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: selected ? kPrimary : kLocked),
        ),
        child: Text(
          '$label $count',
          style: TextStyle(color: selected ? kPrimary : Colors.white60, fontSize: 13),
        ),
      ),
    );
  }
}

class _GradeChip extends StatelessWidget {
  const _GradeChip({
    required this.label,
    required this.color,
    required this.active,
    required this.onTap,
  });

  final String label;
  final Color color;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(999),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color: active ? color.withValues(alpha: 0.18) : Colors.transparent,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: active ? color : kLocked),
        ),
        child: Text(
          label,
          style: TextStyle(color: active ? color : Colors.white60, fontSize: 13),
        ),
      ),
    );
  }
}

Widget _tierBadge(String tier) => _badge(tier, tierColor(tier));

Widget _badge(String text, Color color) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Text(text, style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w600)),
    );

Color tierColor(String tier) {
  switch (tier) {
    case 'T0':
      return kPrimary;
    case 'T1':
      return const Color(0xFF6FA8FF);
    default:
      return Colors.white54;
  }
}
