import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'models/content_pack.dart';
import 'screens/free_build_screen.dart';
import 'screens/level.dart';
import 'screens/library.dart';
import 'screens/map.dart';
import 'screens/review.dart';
import 'services/chunk_asset.dart';
import 'services/chunk_progress.dart';
import 'services/crash_log.dart';
import 'services/loaders.dart';
import 'services/speech.dart';
import 'services/state_machine.dart';
import 'services/vosk_engine.dart';
import 'steps/practice_loop.dart';
import 'ui/theme.dart';

/// E2E 专用入口（不参与生产包）：录音走真实麦克风，识别文本按脚本注入，
/// 用于回归「命中 / 未命中 / 重试 / 跳过 / 12/12 完成」五节点状态机。
/// 生产入口 main.dart 不设置注入，判定仍由真实 Vosk + judgeSpeech 完成。
class _ScriptedTranscriber implements Transcriber {
  final bool alwaysHit;
  _ScriptedTranscriber({this.alwaysHit = false});
  final Map<String, int> _calls = {};

  @override
  bool get isReady => true;

  @override
  bool get failed => false;

  @override
  Future<bool> init() async => true;

  @override
  Future<VoskResult> transcribe(String wavPath, List<String> phrases) async {
    final target = phrases.isEmpty ? '' : phrases.first;
    final n = (_calls[target] ?? 0) + 1;
    _calls[target] = n;
    if (alwaysHit) return VoskResult(target, null);
    // 第 1 句首试注入「另一句」→ 必须判未命中；重试注入正句 → 命中。
    if (target == 'Good morning, everyone.' && n == 1) {
      return const VoskResult("I'm fine, thank you.", null);
    }
    return VoskResult(target, null);
  }
}

/// 造一块「base 当天学完」的资产（巩固中、次日到期），走真实事件链路。
Future<void> _seedReviewChunk(
    ProgressService progress, DateTime base, String chunkId) async {
  await progress.chunkStore.db.resetChunks();
  final seedStore =
      ChunkProgressStore(progress.chunkStore.db, clock: () => base);
  await seedStore.applyEvent(chunkId, ChunkEvent.assembleCorrect);
  await seedStore.applyEvent(chunkId, ChunkEvent.dragCorrect);
  await seedStore.applyEvent(chunkId, ChunkEvent.accuracyPass, accuracy: 100);
  await seedStore.applyEvent(chunkId, ChunkEvent.speakSuccess, accuracy: 100);
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  const alwaysHit = bool.fromEnvironment('E2E_ALWAYS_HIT');
  SpeechService.debugTranscriberOverride =
      _ScriptedTranscriber(alwaysHit: alwaysHit);
  const startChallenge =
      bool.fromEnvironment('E2E_START_CHALLENGE', defaultValue: true);
  const seedCount = int.fromEnvironment('E2E_SEED_COUNT', defaultValue: 0);
  const seedBCount = int.fromEnvironment('E2E_SEED_B_COUNT', defaultValue: 0);
  const screen = String.fromEnvironment('E2E_SCREEN', defaultValue: 'level');
  // 波 1 复习引擎时间加速：固定「今天」，配合 E2E_SEED_REVIEW 造一块昨天学的到期块。
  const fakeNowStr = String.fromEnvironment('E2E_FAKE_NOW', defaultValue: '');
  final fakeNow = fakeNowStr.isEmpty ? null : DateTime.tryParse(fakeNowStr);
  const seedReview = bool.fromEnvironment('E2E_SEED_REVIEW', defaultValue: false);
  const resetChunks = bool.fromEnvironment('E2E_RESET', defaultValue: false);
  const seedChunkId =
      String.fromEnvironment('E2E_SEED_CHUNK', defaultValue: 'a03');
  PracticeLoop.debugStartChallenge = startChallenge;
  try {
    final progress =
        ProgressService(clock: fakeNow == null ? null : () => fakeNow);
    await progress.init();
    final content = await loadContentPack();
    final tts = TtsService();
    await tts.init();
    final level = content.levels.firstWhere((l) => l.id == 'A',
        orElse: () => content.levels.first);
    if (resetChunks) {
      await progress.chunkStore.db.resetChunks();
      await progress.clearLearnResume(level.id);
    }
    if (seedReview) {
      // 用「昨天」的时钟走真实学习事件 → 资产巩固中、今日到期。
      await _seedReviewChunk(progress,
          (fakeNow ?? DateTime.now()).subtract(const Duration(days: 1)),
          seedChunkId);
    }
    if (seedCount > 0 || seedBCount > 0) {
      await progress.chunkStore.db.resetChunks();
      Future<void> seed(Level lv, int n) async {
        for (final c in lv.chunks.take(n)) {
          await progress.chunkStore.applyEvent(c.id, ChunkEvent.assembleCorrect);
          await progress.chunkStore.applyEvent(c.id, ChunkEvent.dragCorrect);
          await progress.chunkStore
              .applyEvent(c.id, ChunkEvent.accuracyPass, accuracy: 100);
          await progress.chunkStore
              .applyEvent(c.id, ChunkEvent.speakSuccess, accuracy: 100);
        }
      }

      await seed(level, seedCount);
      final b = content.levels.firstWhere((l) => l.id == 'B',
          orElse: () => content.levels.first);
      await seed(b, seedBCount);
      // 造数会跨过 10/25 里程碑；E2E 只看推进链路，先记为已庆祝避免弹窗打断。
      for (final m in ProgressService.kMilestones) {
        if (m <= seedCount + seedBCount) await progress.markMilestoneCelebrated(m);
      }
    }
    final home = screen == 'map'
        ? const MapScreen()
        : screen == 'review'
            ? const ReviewScreen()
            : screen == 'cycle'
                ? _CycleScreen(
                    progress: progress, start: fakeNow ?? DateTime.now())
                : screen == 'menu'
                    ? _E2eMenu(
                        progress: progress,
                        fakeNow: fakeNow ?? DateTime.now(),
                        seedChunkId: seedChunkId)
                    : screen == 'w2learn' || screen == 'w2review'
                        ? _W2Screen(
                            progress: progress,
                            level: level,
                            chunk: level.chunks.first,
                            fakeNow: fakeNow ?? DateTime.now(),
                            review: screen == 'w2review')
                        : screen == 'library'
                            ? const LibraryScreen()
                            : screen == 'freebuild'
                                ? FreeBuildScreen(
                                    learnedChunks: level.chunks.take(10).toList())
                                : LevelScreen(level: level);
    runZonedGuarded(() {
      runApp(
        MultiProvider(
          providers: [
            Provider<ProgressService>.value(value: progress),
            Provider<ContentPack>.value(value: content),
            Provider<TtsService>.value(value: tts),
          ],
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: darkTheme,
            builder: (context, child) => Stack(
              children: [
                if (child != null) Positioned.fill(child: child),
                const Positioned(
                  top: 0,
                  right: 0,
                  child: Material(
                    color: Color(0xCC7A4DFF),
                    child: Padding(
                      padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      child: Text('E2E · 识别结果脚本注入',
                          style: TextStyle(color: Colors.white, fontSize: 11)),
                    ),
                  ),
                ),
              ],
            ),
            home: home,
          ),
        ),
      );
    }, (e, st) => CrashLog.write('E2E uncaught: $e', st));
  } catch (e, st) {
    CrashLog.write('E2E bootstrap: $e', st);
    runApp(MaterialApp(
      home: Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: Text('E2E 启动失败：$e',
              style: const TextStyle(color: Colors.white)),
        ),
      ),
    ));
  }
}

/// E2E 控制台：一个包内切换全周期 / 今日复习 / 首页下次复习，避免多次重编译。
class _E2eMenu extends StatelessWidget {
  final ProgressService progress;
  final DateTime fakeNow;
  final String seedChunkId;
  const _E2eMenu(
      {required this.progress,
      required this.fakeNow,
      required this.seedChunkId});

  void _push(BuildContext context, Widget page) {
    Navigator.push(context, MaterialPageRoute(builder: (_) => page));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBg,
      appBar: AppBar(title: const Text('E2E · 波 1 验收控制台')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text('假时钟 ${fakeNow.year}-${fakeNow.month}-${fakeNow.day}',
              style: const TextStyle(color: Colors.white54)),
          const SizedBox(height: 20),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
                backgroundColor: kPrimary,
                padding: const EdgeInsets.symmetric(vertical: 16)),
            onPressed: () => _push(
                context,
                _CycleScreen(progress: progress, start: fakeNow)),
            child: const Text('① 资产全周期（时间加速 1d/3d/7d/14d）',
                style: TextStyle(color: Colors.white)),
          ),
          const SizedBox(height: 12),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
                backgroundColor: kCard,
                padding: const EdgeInsets.symmetric(vertical: 16)),
            onPressed: () async {
              await _seedReviewChunk(progress,
                  fakeNow.subtract(const Duration(days: 1)), seedChunkId);
              if (context.mounted) _push(context, const ReviewScreen());
            },
            child: const Text('② 今日复习（1 块到期，走真实四步 UI）',
                style: TextStyle(color: Colors.white)),
          ),
          const SizedBox(height: 12),
          OutlinedButton(
            style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 16)),
            onPressed: () async {
              // 今天学完 → 明天到期，首页应显示「下次复习：明天」。
              await _seedReviewChunk(progress, fakeNow, seedChunkId);
              if (context.mounted) _push(context, const MapScreen());
            },
            child: const Text('③ 首页「下次复习」字段（明天到期）',
                style: TextStyle(color: kPrimary)),
          ),
        ],
      ),
    );
  }
}

/// 波 2 E2E：真实六步 UI / 真实四步复习 UI 的自动走查。
/// 只在本 E2E 入口启用：用合成指针事件点真实控件，识别结果仍由脚本注入。
/// 记一笔时钟来源，免得把「假时钟加速」当成「真实次日」汇报。
const String _fakeNowRaw = String.fromEnvironment('E2E_FAKE_NOW', defaultValue: '');
final bool fakeNowUsed = _fakeNowRaw.isNotEmpty;

class _W2Screen extends StatefulWidget {
  final ProgressService progress;
  final Level level;
  final Chunk chunk;
  final DateTime fakeNow;
  final bool review;
  const _W2Screen({
    required this.progress,
    required this.level,
    required this.chunk,
    required this.fakeNow,
    required this.review,
  });

  @override
  State<_W2Screen> createState() => _W2ScreenState();
}

class _W2ScreenState extends State<_W2Screen> {
  String _status = '准备中…';
  bool _done = false;
  bool _ok = false;

  String get _md =>
      '${widget.fakeNow.year}-${widget.fakeNow.month}-${widget.fakeNow.day}';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _run());
  }

  Future<void> _run() async {
    await Future.delayed(const Duration(seconds: 2));
    if (!mounted) return;
    final auto = _W2Auto(chunk: widget.chunk, review: widget.review);
    setState(() => _status = widget.review ? '次日复习运行中…' : '六步学习运行中…');
    final ok = widget.review
        ? await auto.runReview(context, widget.level)
        : await auto.runLearn(context, widget.level);
    if (!mounted) return;
    if (!ok) {
      setState(() {
        _status = '流程中断：${auto.failure}（详见 logcat E2E_W2）';
        _done = true;
      });
      return;
    }
    Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => const LibraryScreen()));
    final ok2 = await auto.inspectLibraryAndExport();
    if (!mounted) return;
    setState(() {
      _done = true;
      _ok = ok2;
      _status = ok2 ? '波 2 全流程 PASS（检查项见 logcat）' : '流程完成，检查项有 FAIL';
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBg,
      appBar: AppBar(title: const Text('E2E · 波 2 验收控制台')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text('取用时钟 $_md · ${widget.review ? '次日复习' : '六步学习'}'
              '${fakeNowUsed ? '（E2E_FAKE_NOW 加速）' : '（设备真实时钟）'}',
              style: const TextStyle(color: Colors.white54)),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: kCard,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                  color: _done ? (_ok ? kUnlocked : Colors.redAccent) : kPrimary),
            ),
            child: Text(_status,
                style: TextStyle(
                    color: _done
                        ? (_ok ? kUnlocked : Colors.redAccent)
                        : kPrimary,
                    fontSize: 16,
                    fontWeight: FontWeight.w700)),
          ),
          const SizedBox(height: 16),
          const Text('流程：六步学习 → 词块库 → 次日复习升档 → 导出学习数据',
              style: TextStyle(color: Colors.white38, fontSize: 12)),
        ],
      ),
    );
  }
}

class _W2Auto {
  final Chunk chunk;
  final bool review;
  _W2Auto({required this.chunk, required this.review});

  int _pointer = 900;
  String failure = '';
  final List<String> _checks = [];

  void _log(String s) => debugPrint('E2E_W2|$s');

  void _check(String name, bool ok, String detail) {
    _checks.add('$name=${ok ? 'PASS' : 'FAIL'}');
    _log('${ok ? 'PASS' : 'FAIL'}|$name|$detail');
  }

  Element? _find(bool Function(Widget w) pred) {
    Element? hit;
    void visit(Element e) {
      if (hit != null) return;
      if (pred(e.widget)) {
        hit = e;
        return;
      }
      e.visitChildren(visit);
    }

    final root = WidgetsBinding.instance.rootElement;
    if (root != null) visit(root);
    return hit;
  }

  Element? _findText(String text, {bool prefix = false}) => _find((w) {
        if (w is Text) {
          final d = w.data;
          if (d == null) return false;
          return prefix ? d.startsWith(text) : d == text;
        }
        return false;
      });

  /// 点按用：同名文本/图标可能在底层路由（如复习列表）也有一份，
  /// 只返回当前命中测试真正落在其上的那一个，避免点到被遮挡或已滑出的副本。
  Element? _topmostWhere(bool Function(Widget w) test) {
    final matches = <Element>[];
    void visit(Element e) {
      if (test(e.widget)) matches.add(e);
      e.visitChildren(visit);
    }

    final root = WidgetsBinding.instance.rootElement;
    if (root != null) visit(root);
    for (final e in matches.reversed) {
      final ro = e.renderObject;
      if (ro is! RenderBox || !ro.attached || ro.size.isEmpty) continue;
      final pos = ro.localToGlobal(ro.size.center(Offset.zero));
      if (pos.dx < 0 || pos.dy < 0) continue; // 已滑出屏幕的路由不算命中
      final result = HitTestResult();
      WidgetsBinding.instance.hitTestInView(result, pos, View.of(e).viewId);
      if (result.path.any((entry) => entry.target == ro)) return e;
    }
    return matches.isEmpty ? null : matches.last;
  }

  Element? _findTappableText(String text, {bool prefix = false}) =>
      _topmostWhere((w) {
        if (w is! Text) return false;
        final d = w.data;
        return d != null && (prefix ? d.startsWith(text) : d == text);
      });

  Element? _findIcon(IconData icon) =>
      _topmostWhere((w) => w is Icon && w.icon == icon);

  bool _hasText(String text, {bool prefix = false}) =>
      _findText(text, prefix: prefix) != null;

  Future<bool> _wait(bool Function() cond, String what,
      {Duration timeout = const Duration(seconds: 25)}) async {
    final end = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(end)) {
      if (cond()) return true;
      await Future.delayed(const Duration(milliseconds: 120));
    }
    failure = '等待超时：$what';
    _log('TIMEOUT|$what');
    return false;
  }

  Future<bool> _waitText(String text,
          {bool prefix = false,
          Duration timeout = const Duration(seconds: 25)}) =>
      _wait(() => _hasText(text, prefix: prefix), '文本「$text」',
          timeout: timeout);

  Future<bool> _waitNoIcon(IconData icon,
          {Duration timeout = const Duration(seconds: 10)}) =>
      _wait(() => _findIcon(icon) == null, '图标消失 $icon', timeout: timeout);

  Future<bool> _tap(Element? e, String what) async {
    if (e == null) {
      failure = '找不到控件：$what';
      _log('MISSING|$what');
      return false;
    }
    final ro = e.renderObject;
    if (ro is! RenderBox || !ro.attached || ro.size.isEmpty) {
      failure = '控件不可见：$what';
      _log('INVISIBLE|$what');
      return false;
    }
    final pos = ro.localToGlobal(ro.size.center(Offset.zero));
    final binding = WidgetsBinding.instance;
    final id = _pointer++;
    binding.handlePointerEvent(PointerDownEvent(
        pointer: id, position: pos, kind: PointerDeviceKind.touch));
    await Future.delayed(const Duration(milliseconds: 70));
    binding.handlePointerEvent(PointerUpEvent(
        pointer: id, position: pos, kind: PointerDeviceKind.touch));
    _log('TAP|$what|${pos.dx.toStringAsFixed(0)},${pos.dy.toStringAsFixed(0)}');
    await Future.delayed(const Duration(milliseconds: 350));
    return true;
  }

  Future<bool> _tapText(String text, {bool prefix = false}) async {
    if (!await _waitText(text, prefix: prefix)) return false;
    return _tap(_findTappableText(text, prefix: prefix), '文本「$text」');
  }

  Future<bool> _tapIcon(IconData icon) async {
    if (!await _wait(() => _findIcon(icon) != null, '图标 $icon')) return false;
    return _tap(_findIcon(icon), '图标 $icon');
  }

  List<String> _allTexts() {
    final out = <String>[];
    void visit(Element e) {
      final w = e.widget;
      if (w is Text && w.data != null) out.add(w.data!);
      e.visitChildren(visit);
    }

    final root = WidgetsBinding.instance.rootElement;
    if (root != null) visit(root);
    return out;
  }

  String _firstWithPrefix(String prefix) {
    for (final t in _allTexts()) {
      if (t.startsWith(prefix)) return t;
    }
    return '';
  }

  String _starLine() {
    for (final t in _allTexts()) {
      if (t.contains('⭐')) return t;
    }
    return '';
  }

  // —— 六步学习 ——

  Future<bool> runLearn(BuildContext context, Level level) async {
    _log('START|learn|chunk=${chunk.id}|${chunk.text}');
    final sw = Stopwatch()..start();
    Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => LevelScreen(level: level)));

    if (!await _waitText('开始拆解')) return false;
    await Future.delayed(const Duration(milliseconds: 1200));
    if (!await _tapText('开始拆解')) return false;
    _log('STAGE|breakdown');

    if (!await _waitText('把词块拆开看', prefix: true)) return false;
    for (final w in chunk.text.split(RegExp(r'\s+')).where((x) => x.isNotEmpty)) {
      if (!await _tapText(w)) return false;
    }
    if (!await _waitText('拆完了，拼回去它就长在你嘴里')) return false;
    if (!await _tapText('拼回去 · 去听辨')) return false;

    if (!await _listenRounds(3)) return false;
    if (!await _speakOnce(micWaitText: '影子跟读', nextText: '第 5/6 步 · 定向替换')) {
      return false;
    }
    if (!await _substitute(nextText: '第 6/6 步 · 自由造句')) return false;

    if (!await _waitText('第 6/6 步 · 自由造句')) return false;
    if (!await _tapText('说出来')) return false;
    if (!await _waitText('说完点这里')) return false;
    await Future.delayed(const Duration(milliseconds: 2500));
    if (!await _tapText('说完点这里')) return false;
    _log('STAGE|freeuse_check');
    if (!await _waitText('完成这一块', timeout: const Duration(seconds: 30))) {
      return false;
    }
    if (!await _tapText('完成这一块')) return false;

    if (!await _waitText('本块完成', timeout: const Duration(seconds: 5))) {
      return false;
    }
    _log('STAGE|stamp');
    await Future.delayed(const Duration(milliseconds: 600));
    final star = _starLine();
    _check('六步四星', star.contains('⭐4/4'), star.isEmpty ? '未找到星标' : star);
    sw.stop();
    _check('单块耗时<8分钟', sw.elapsed < const Duration(minutes: 8),
        '${(sw.elapsedMilliseconds / 1000).toStringAsFixed(1)}s');
    _log('LEARN_DONE|${sw.elapsedMilliseconds}ms|$star');

    if (!await _tapIcon(Icons.close)) return false;
    if (!await _waitNoIcon(Icons.close)) return false;
    return true;
  }

  // —— 次日复习（后四步）——

  Future<bool> runReview(BuildContext context, Level level) async {
    _log('START|review|chunk=${chunk.id}');
    Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => const ReviewScreen()));
    if (!await _waitText('开始复习', prefix: true)) return false;
    await Future.delayed(const Duration(milliseconds: 600));
    if (!await _tapText('开始复习', prefix: true)) return false;

    if (!await _listenRounds(2)) return false;
    if (!await _speakOnce(micWaitText: '复习·跟读', nextText: '复习 · 定向替换')) {
      return false;
    }
    if (!await _substitute(nextText: '复习·开口')) return false;

    if (!await _waitText('复习·开口', prefix: true)) return false;
    if (!await _tapIcon(Icons.mic)) return false;
    if (!await _waitText('正在录音', prefix: true)) return false;
    await Future.delayed(const Duration(milliseconds: 2500));
    if (!await _tapIcon(Icons.stop)) return false;

    if (!await _waitText('复习完成', timeout: const Duration(seconds: 30))) {
      return false;
    }
    if (!await _waitText('今天没有待复习词块',
        timeout: const Duration(seconds: 15))) {
      return false;
    }
    _log('REVIEW_DONE|due-cleared');
    // 复习页清空后要点「返回」回控制台：按 BackButton 控件找，别按 Icon——
    // 同名 arrow_back 图标在页面上可能有多份，命中测试会挑到不响应的那个。
    if (!await _tapBackButton()) return false;
    if (!await _wait(() => _topmostWhere((w) => w is BackButton) == null,
        '返回按钮消失')) {
      return false;
    }
    return true;
  }

  Future<bool> _tapBackButton() async {
    if (!await _wait(() => _topmostWhere((w) => w is BackButton) != null,
        '返回按钮')) {
      return false;
    }
    return _tap(_topmostWhere((w) => w is BackButton), '返回按钮');
  }

  Future<bool> _listenRounds(int total) async {
    for (var r = 1; r <= total; r++) {
      if (!await _waitText('听辨 · 第 $r/$total 轮')) return false;
      _log('STAGE|listen_$r');
      await Future.delayed(const Duration(milliseconds: 400));
      if (!await _tapText(chunk.text)) return false;
      if (!await _waitText('这轮听对了！')) return false;
      final next = r < total ? '下一轮' : '完成听辨';
      if (!await _tapText(next, prefix: true)) return false;
    }
    return true;
  }

  Future<bool> _speakOnce(
      {required String micWaitText, required String nextText}) async {
    if (!await _waitText(micWaitText, prefix: true)) return false;
    _log('STAGE|shadow');
    if (!await _tapIcon(Icons.mic)) return false;
    if (!await _waitText('正在录音', prefix: true)) return false;
    await Future.delayed(const Duration(milliseconds: 2500));
    if (!await _tapIcon(Icons.stop)) return false;
    if (!await _waitText(nextText, timeout: const Duration(seconds: 30))) {
      return false;
    }
    _log('STAGE|substitute');
    return true;
  }

  Future<bool> _substitute({required String nextText}) async {
    if (!await _waitText('开口说这句')) return false;
    await Future.delayed(const Duration(milliseconds: 800));
    if (!await _tapText('开口说这句')) return false;
    if (!await _waitText('正在录音 · 说完点停止')) return false;
    await Future.delayed(const Duration(milliseconds: 1500));
    if (!await _tapIcon(Icons.stop)) return false;
    if (!await _waitText('完成替换 · 下一步',
        timeout: const Duration(seconds: 30))) {
      return false;
    }
    if (!await _tapText('完成替换 · 下一步')) return false;
    _log('STAGE|freeuse');
    return true;
  }

  // —— 词块库与导出 ——

  Future<bool> inspectLibraryAndExport() async {
    if (!await _waitText('词块资产库', timeout: const Duration(seconds: 20))) {
      return false;
    }
    await Future.delayed(const Duration(milliseconds: 800));
    final mastered = _firstWithPrefix('已掌握 ');
    final learned = _firstWithPrefix('已学完 ');
    final row = _firstWithPrefix('首学 ');
    final groups = _allTexts()
        .where((t) => t == '巩固中' || t == '长期' || t == '需重修')
        .toList();
    _log('LIB|mastered=$mastered|learned=$learned|groups=$groups|row=$row');

    _check('库头部资产轴计数', mastered == '已掌握 0 个词块', mastered);
    _check('已学完按资产轴', learned.startsWith('已学完 1 /'), learned);
    if (review) {
      _check('复习后升档分组', groups.contains('长期'), groups.join(','));
      _check('复习次数与连对', row.contains('复习 1 次') && row.contains('连对 1'), row);
      // 首到期（+1d）通过后升到 3 天档：10-23 复习 → 下次 10-26。
      _check('下次复习日期', row.contains('下次 10月26日'), row);
    } else {
      // 指令 N 修订：四星全绿 → 已巩固首档，首次到期 = 次日（+1d），仍归入长期分组。
      _check('学习后资产档位', groups.contains('长期'), groups.join(','));
      _check('首次学习日期', row.contains('首学 10月22日'), row);
      _check('复习次数为0', row.contains('复习 0 次'), row);
      _check('四星排次日到期', row.contains('下次 10月23日'), row);
    }

    if (!await _tapText('导出')) return false;
    if (!await _waitText('学习数据已生成')) return false;
    await Future.delayed(const Duration(milliseconds: 400));
    final pathEl =
        _find((w) => w is SelectableText && (w.data ?? '').contains('/data/'));
    final path = pathEl is Element
        ? ((pathEl.widget as SelectableText).data ?? '')
        : '';
    _log('EXPORT|$path');
    _check('导出文件已生成', path.contains('chunkspoke_learning_'), path);
    return _checks.every((c) => c.endsWith('PASS'));
  }
}

class _TickClock {
  _TickClock(this.now);
  DateTime now;
  DateTime call() => now;
  void advance(Duration d) => now = now.add(d);
}

class _CycleRow {
  final String step;
  final bool ok;
  final String detail;
  const _CycleRow(this.step, this.ok, this.detail);
}

/// 波 1 E2E：在真实设备库里用假时钟跑完 1d/3d/7d/14d 全周期，
/// 每一步都走真实的 ChunkProgressStore.applyEvent / reviewQueue，
/// 结果逐行上屏并写入 logcat（E2E_CYCLE 前缀）供证据留存。
class _CycleScreen extends StatefulWidget {
  final ProgressService progress;
  final DateTime start;
  const _CycleScreen({required this.progress, required this.start});

  @override
  State<_CycleScreen> createState() => _CycleScreenState();
}

class _CycleScreenState extends State<_CycleScreen> {
  final List<_CycleRow> _rows = [];
  bool _running = true;
  String _error = '';

  @override
  void initState() {
    super.initState();
    _run();
  }

  String _md(DateTime d) => '${d.month}月${d.day}日';
  String _fmt(int ms) =>
      ms == 0 ? '不排期' : _md(DateTime.fromMillisecondsSinceEpoch(ms));

  void _add(String step, bool ok, String detail) {
    _rows.add(_CycleRow(step, ok, detail));
    debugPrint('E2E_CYCLE|${ok ? 'PASS' : 'FAIL'}|$step|$detail');
  }

  Future<void> _run() async {
    const key = 'a03';
    try {
      final clock = _TickClock(widget.start);
      final db = widget.progress.chunkStore.db;
      await db.resetChunks();
      final s = ChunkProgressStore(db, clock: clock.call);

      await s.applyEvent(key, ChunkEvent.assembleCorrect);
      await s.applyEvent(key, ChunkEvent.dragCorrect);
      await s.applyEvent(key, ChunkEvent.accuracyPass, accuracy: 100);
      await s.applyEvent(key, ChunkEvent.speakSuccess, accuracy: 100);
      var r = await s.get(key);
      final due1 = clock.now.add(const Duration(days: 1));
      _add(
          'D+0 学习完成',
          r.assetState == ChunkAssetState.consolidating &&
              r.reviewStage == 0 &&
              r.dueDate == due1.millisecondsSinceEpoch &&
              r.firstLearnedAt == clock.now.millisecondsSinceEpoch,
          '${r.assetState.label} · ${_md(due1)} 到期');

      await _step(s, clock,
          day: 1,
          advance: 1,
          expectState: ChunkAssetState.consolidated,
          expectStage: 1,
          nextInterval: 3);
      await _step(s, clock,
          day: 4,
          advance: 3,
          expectState: ChunkAssetState.longTerm,
          expectStage: 2,
          nextInterval: 7);
      await _step(s, clock,
          day: 11,
          advance: 7,
          expectState: ChunkAssetState.longTerm,
          expectStage: 3,
          nextInterval: 14);
      await _step(s, clock,
          day: 25,
          advance: 14,
          expectState: ChunkAssetState.mastered,
          expectStage: 4,
          nextInterval: null);

      final assets = await s.exportAssets();
      final m = assets.singleWhere((e) => e['chunk_key'] == key);
      _add(
          '🎓 全量导出',
          m['asset_state'] == 'mastered' &&
              m['review_count'] == 4 &&
              m['correct_streak'] == 4 &&
              m['due_date'] == 0,
          '状态=${m['asset_label']} 复习=${m['review_count']} 连对=${m['correct_streak']} 到期=${m['due_date']}');
      final q = await s.reviewQueue(clock.now);
      final next = await s.nextDueTimestamp(clock.now.millisecondsSinceEpoch);
      _add('队列清空', q.items.isEmpty && q.dueTotal == 0 && next == null,
          'dueTotal=${q.dueTotal} next=$next');
    } catch (e, st) {
      CrashLog.write('E2E cycle: $e', st);
      if (mounted) {
        setState(() {
          _error = '$e';
          _running = false;
        });
      }
      return;
    }
    if (mounted) setState(() => _running = false);
  }

  Future<void> _step(
    ChunkProgressStore s,
    _TickClock clock, {
    required int day,
    required int advance,
    required ChunkAssetState expectState,
    required int expectStage,
    required int? nextInterval,
  }) async {
    const key = 'a03';
    clock.advance(Duration(days: advance));
    final q = await s.reviewQueue(clock.now);
    final dueHit = q.items.any((e) => e.chunkKey == key);
    _add('D+$day 到期入队', dueHit && q.dueTotal >= 1,
        '今日到期=${q.dueTotal} 队列=${q.items.length}');

    await s.applyEvent(key, ChunkEvent.speakSuccess,
        accuracy: 100, review: true);
    final r = await s.get(key);
    final expectDue = nextInterval == null
        ? 0
        : clock.now.add(Duration(days: nextInterval)).millisecondsSinceEpoch;
    _add(
        'D+$day 复习通过',
        r.assetState == expectState &&
            r.reviewStage == expectStage &&
            r.dueDate == expectDue,
        '${r.assetState.label} 档=${r.reviewStage} 到期=${_fmt(r.dueDate)} 连对=${r.correctStreak}');
  }

  @override
  Widget build(BuildContext context) {
    final passed = _rows.where((r) => r.ok).length;
    final allOk = !_running && _error.isEmpty && passed == _rows.length;
    return Scaffold(
      backgroundColor: kBg,
      appBar: AppBar(title: const Text('E2E · 词块资产全周期（时间加速）')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('起点 ${_md(widget.start)} · 1d → 3d → 7d → 14d',
              style: const TextStyle(color: Colors.white54, fontSize: 13)),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: kCard,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                  color: allOk ? kUnlocked : (_error.isEmpty ? kPrimary : Colors.redAccent)),
            ),
            child: Text(
              _running
                  ? '运行中…'
                  : (_error.isEmpty
                      ? (allOk ? '全周期 PASS · $passed/${_rows.length}' : '存在 FAIL')
                      : '中断：$_error'),
              style: TextStyle(
                  color: allOk
                      ? kUnlocked
                      : (_error.isEmpty ? kPrimary : Colors.redAccent),
                  fontSize: 20,
                  fontWeight: FontWeight.w800),
            ),
          ),
          const SizedBox(height: 12),
          for (final row in _rows)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 5),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(row.ok ? Icons.check_circle : Icons.error,
                      color: row.ok ? kUnlocked : Colors.redAccent, size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text('${row.step}  ${row.detail}',
                        style: const TextStyle(
                            color: Colors.white, fontSize: 14)),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
