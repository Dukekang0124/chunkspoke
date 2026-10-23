import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:provider/provider.dart';

import 'models/content_pack.dart';
import 'models/listening_article.dart';
import 'screens/free_build_screen.dart';
import 'screens/level.dart';
import 'screens/library.dart';
import 'screens/listening_player.dart';
import 'screens/map.dart';
import 'screens/review.dart';
import 'services/chunk_asset.dart';
import 'services/chunk_progress.dart';
import 'services/crash_log.dart';
import 'services/listening_palette.dart';
import 'services/database.dart';
import 'services/learning_export.dart';
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

  @override
  Future<VoskResult> transcribeOpen(String wavPath) =>
      transcribe(wavPath, const []);
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

/// 截图根节点：Q-3 走查要按真实 UI 状态留证，包住 MaterialApp 连浮层与 SnackBar。
final GlobalKey e2eRootKey = GlobalKey();

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
  const seedReview =
      bool.fromEnvironment('E2E_SEED_REVIEW', defaultValue: false);
  const resetChunks = bool.fromEnvironment('E2E_RESET', defaultValue: false);
  const seedChunkId =
      String.fromEnvironment('E2E_SEED_CHUNK', defaultValue: 'a03');
  PracticeLoop.debugStartChallenge = startChallenge;
  try {
    final progress =
        ProgressService(clock: fakeNow == null ? null : () => fakeNow);
    await progress.init();
    final content = await loadContentPack();
    final listening = screen == 'q3' ? await loadListeningPack() : null;
    final tts = TtsService();
    // 压测腿不听示范音：Google TTS 冷启动可能几十秒不回调，别把整条流程卡在启动页。
    try {
      await tts.init().timeout(const Duration(seconds: 10));
    } catch (_) {}
    final level = content.levels
        .firstWhere((l) => l.id == 'A', orElse: () => content.levels.first);
    if (resetChunks) {
      await progress.chunkStore.db.resetChunks();
      await progress.clearLearnResume(level.id);
    }
    if (seedReview) {
      // 用「昨天」的时钟走真实学习事件 → 资产巩固中、今日到期。
      await _seedReviewChunk(
          progress,
          (fakeNow ?? DateTime.now()).subtract(const Duration(days: 1)),
          seedChunkId);
    }
    if (seedCount > 0 || seedBCount > 0) {
      await progress.chunkStore.db.resetChunks();
      Future<void> seed(Level lv, int n) async {
        for (final c in lv.chunks.take(n)) {
          await progress.chunkStore
              .applyEvent(c.id, ChunkEvent.assembleCorrect);
          await progress.chunkStore.applyEvent(c.id, ChunkEvent.dragCorrect);
          await progress.chunkStore
              .applyEvent(c.id, ChunkEvent.accuracyPass, accuracy: 100);
          await progress.chunkStore
              .applyEvent(c.id, ChunkEvent.speakSuccess, accuracy: 100);
        }
      }

      await seed(level, seedCount);
      final b = content.levels
          .firstWhere((l) => l.id == 'B', orElse: () => content.levels.first);
      await seed(b, seedBCount);
      // 造数会跨过 10/25 里程碑；E2E 只看推进链路，先记为已庆祝避免弹窗打断。
      for (final m in ProgressService.kMilestones) {
        if (m <= seedCount + seedBCount) {
          await progress.markMilestoneCelebrated(m);
        }
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
                        : screen == 'q3'
                            ? _Q3Screen(
                                progress: progress,
                                content: content,
                                listening: listening!)
                            : screen == 'library'
                            ? const LibraryScreen()
                            : screen == 'freebuild'
                                ? FreeBuildScreen(
                                    learnedChunks:
                                        level.chunks.take(10).toList())
                                : screen == 'sandbox'
                                    ? _SandboxStress(
                                        progress: progress, tts: tts)
                                    : LevelScreen(level: level);
    runZonedGuarded(() {
      runApp(
        MultiProvider(
          providers: [
            Provider<ProgressService>.value(value: progress),
            Provider<ContentPack>.value(value: content),
            Provider<TtsService>.value(value: tts),
          ],
          child: RepaintBoundary(
            key: e2eRootKey,
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
                        padding: EdgeInsets.symmetric(
                            horizontal: 8, vertical: 4),
                        child: Text('E2E · 识别结果脚本注入',
                            style: TextStyle(
                                color: Colors.white, fontSize: 11)),
                      ),
                    ),
                  ),
                ],
              ),
              home: home,
            ),
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
          child:
              Text('E2E 启动失败：$e', style: const TextStyle(color: Colors.white)),
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
                context, _CycleScreen(progress: progress, start: fakeNow)),
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
const String _fakeNowRaw =
    String.fromEnvironment('E2E_FAKE_NOW', defaultValue: '');
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
    Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => const LibraryScreen()));
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
          Text(
              '取用时钟 $_md · ${widget.review ? '次日复习' : '六步学习'}'
              '${fakeNowUsed ? '（E2E_FAKE_NOW 加速）' : '（设备真实时钟）'}',
              style: const TextStyle(color: Colors.white54)),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: kCard,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                  color:
                      _done ? (_ok ? kUnlocked : Colors.redAccent) : kPrimary),
            ),
            child: Text(_status,
                style: TextStyle(
                    color:
                        _done ? (_ok ? kUnlocked : Colors.redAccent) : kPrimary,
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

/// 合成指针驱动真实控件的公共能力（E2E 专用，不进生产包）。
mixin _AutoUi {
  int _pointer = 900;
  String failure = '';
  final List<String> _checks = [];

  /// logcat 前缀，便于按流程过滤。
  String get logTag;

  bool get allPassed => _checks.every((c) => c.endsWith('PASS'));

  void _log(String s) => debugPrint('$logTag|$s');

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
}

class _W2Auto with _AutoUi {
  final Chunk chunk;
  final bool review;
  _W2Auto({required this.chunk, required this.review});

  @override
  String get logTag => 'E2E_W2';

  // —— 六步学习 ——

  Future<bool> runLearn(BuildContext context, Level level) async {
    _log('START|learn|chunk=${chunk.id}|${chunk.text}');
    final sw = Stopwatch()..start();
    Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => LevelScreen(level: level)));

    if (!await _waitText('开始拆解')) return false;
    await Future.delayed(const Duration(milliseconds: 1200));
    if (!await _tapText('开始拆解')) return false;
    _log('STAGE|breakdown');

    if (!await _waitText('把词块拆开看', prefix: true)) return false;
    for (final w
        in chunk.text.split(RegExp(r'\s+')).where((x) => x.isNotEmpty)) {
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
    if (!await _waitText('今天没有待复习词块', timeout: const Duration(seconds: 15))) {
      return false;
    }
    _log('REVIEW_DONE|due-cleared');
    // 复习页清空后要点「返回」回控制台：按 BackButton 控件找，别按 Icon——
    // 同名 arrow_back 图标在页面上可能有多份，命中测试会挑到不响应的那个。
    if (!await _tapBackButton()) return false;
    if (!await _wait(
        () => _topmostWhere((w) => w is BackButton) == null, '返回按钮消失')) {
      return false;
    }
    return true;
  }

  Future<bool> _tapBackButton() async {
    if (!await _wait(
        () => _topmostWhere((w) => w is BackButton) != null, '返回按钮')) {
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
    if (!await _waitText('完成替换 · 下一步', timeout: const Duration(seconds: 30))) {
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
    final path =
        pathEl is Element ? ((pathEl.widget as SelectableText).data ?? '') : '';
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
                  color: allOk
                      ? kUnlocked
                      : (_error.isEmpty ? kPrimary : Colors.redAccent)),
            ),
            child: Text(
              _running
                  ? '运行中…'
                  : (_error.isEmpty
                      ? (allOk
                          ? '全周期 PASS · $passed/${_rows.length}'
                          : '存在 FAIL')
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
                        style:
                            const TextStyle(color: Colors.white, fontSize: 14)),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

// ——————————————————————————————————————————————
// 指令 O：自由造句沙盒压测（200 块夹具）——布局闸门 + 真机全链路留证
// ——————————————————————————————————————————————

/// 压测夹具：N 个块分两个场景（a* 打招呼 / b* 机场），表面形态互不相同。
List<Chunk> _sbPool(int n) => [
      for (var i = 0; i < n; i++)
        Chunk.fromJson({
          'id': '${i % 2 == 0 ? 'a' : 'b'}$i',
          'text': 'say$i now',
          'type': 'content',
          'meaningCN': '释义$i',
        }),
    ];

/// 夹具内容包：沙盒的场景标签与分组数据源（生产内容只有 20 来块，压不出 200 块）。
ContentPack _sbPack(List<Chunk> pool) => ContentPack(version: 'e2e', levels: [
      Level(
        id: 'A',
        theme: '打招呼',
        sceneImage: '',
        chunks: pool.where((c) => c.id.startsWith('a')).toList(),
        sentences: const [],
      ),
      Level(
        id: 'B',
        theme: '机场',
        sceneImage: '',
        chunks: pool.where((c) => c.id.startsWith('b')).toList(),
        sentences: const [],
      ),
    ]);

class _SbRow {
  final String name;
  final bool ok;
  final String detail;
  const _SbRow(this.name, this.ok, this.detail);
}

class _SandboxStress extends StatefulWidget {
  final ProgressService progress;
  final TtsService tts;
  const _SandboxStress({required this.progress, required this.tts});

  @override
  State<_SandboxStress> createState() => _SandboxStressState();
}

class _SandboxStressState extends State<_SandboxStress> {
  final List<_SbRow> _rows = [];
  bool _running = true;
  String _error = '';

  void _add(String name, bool ok, String detail) =>
      setState(() => _rows.add(_SbRow(name, ok, detail)));

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _run());
  }

  Future<void> _run() async {
    final auto =
        _SbAuto(progress: widget.progress, tts: widget.tts, onRow: _add);
    try {
      await auto.run(context);
    } catch (e, st) {
      CrashLog.write('E2E sandbox stress: $e', st);
      if (mounted) setState(() => _error = '$e');
    }
    if (mounted) setState(() => _running = false);
  }

  @override
  Widget build(BuildContext context) {
    final passed = _rows.where((r) => r.ok).length;
    final allOk = !_running && _error.isEmpty && passed == _rows.length;
    return Scaffold(
      backgroundColor: kBg,
      appBar: AppBar(title: const Text('E2E · 沙盒压测（200 块夹具）')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: kCard,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                  color: _running
                      ? kPrimary
                      : (allOk ? kUnlocked : Colors.redAccent)),
            ),
            child: Text(
              _running
                  ? '压测运行中…'
                  : (_error.isEmpty
                      ? (allOk
                          ? '沙盒压测 PASS · $passed/${_rows.length}'
                          : '沙盒压测存在 FAIL · $passed/${_rows.length}')
                      : '中断：$_error'),
              style: TextStyle(
                  color: _running
                      ? kPrimary
                      : (allOk ? kUnlocked : Colors.redAccent),
                  fontSize: 19,
                  fontWeight: FontWeight.w800),
            ),
          ),
          const SizedBox(height: 12),
          for (final r in _rows)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 5),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(r.ok ? Icons.check_circle : Icons.error,
                      color: r.ok ? kUnlocked : Colors.redAccent, size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text('${r.name}\n${r.detail}',
                        style:
                            const TextStyle(color: Colors.white, fontSize: 13)),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _SbAuto with _AutoUi {
  _SbAuto({
    required this.progress,
    required this.tts,
    required this.onRow,
  });

  @override
  String get logTag => 'E2E_SB';

  final ProgressService progress;
  final TtsService tts;
  final void Function(String name, bool ok, String detail) onRow;

  late BuildContext _ctx;
  final List<int> _frameMs = [];

  static const _regions = [
    'sandboxSentenceCard',
    'sandboxFeedbackSlot',
    'sandboxFilterBar',
    'sandboxPool',
    'sandboxDock',
  ];

  @override
  void _check(String name, bool ok, String detail) {
    super._check(name, ok, detail);
    onRow(name, ok, detail);
  }

  NavigatorState get _nav => Navigator.of(_ctx);

  Future<void> _pause([int ms = 400]) =>
      Future<void>.delayed(Duration(milliseconds: ms));

  void _fail(String what) => throw StateError('$failure（$what）');

  Element? _byKey(String key) => _find((w) => w.key == Key(key));

  Rect? _rect(String key) {
    final ro = _byKey(key)?.renderObject;
    if (ro is! RenderBox || !ro.attached || ro.size.isEmpty) return null;
    return ro.localToGlobal(Offset.zero) & ro.size;
  }

  Map<String, Rect> _skeleton() => {
        for (final k in _regions) k: _rect(k) ?? Rect.zero,
      };

  /// release 包里 Rect.toString() 只剩「Instance of 'Rect'」，自己拼数字。
  String _fmt(Rect? r) => r == null
      ? 'null'
      : 'L${r.left.toStringAsFixed(1)} T${r.top.toStringAsFixed(1)} '
          '${r.width.toStringAsFixed(1)}x${r.height.toStringAsFixed(1)}';

  String _diff(Map<String, Rect> a, Map<String, Rect> b) {
    final out = <String>[];
    for (final k in a.keys) {
      if (a[k] != b[k]) out.add('$k ${_fmt(a[k])}→${_fmt(b[k])}');
    }
    return out.join(' | ');
  }

  int _renderedChips() => _allTexts()
      .where((t) => t.startsWith('say') && t.endsWith(' now'))
      .length;

  void _onTimings(List<FrameTiming> timings) {
    for (final t in timings) {
      _frameMs.add((t.buildDuration + t.rasterDuration).inMilliseconds);
    }
  }

  Future<void> _open(List<Chunk> pool) async {
    _nav.push(MaterialPageRoute(
      builder: (_) => MultiProvider(
        providers: [
          Provider<ProgressService>.value(value: progress),
          Provider<ContentPack>.value(value: _sbPack(pool)),
          Provider<TtsService>.value(value: tts),
        ],
        child: FreeBuildScreen(learnedChunks: pool),
      ),
    ));
    if (!await _wait(() => _byKey('sandboxPool') != null, '沙盒块池渲染',
        timeout: const Duration(seconds: 40))) {
      _fail('open');
    }
    await _pause(600);
  }

  Future<void> _close() async {
    if (_nav.canPop()) _nav.pop();
    await _pause(500);
  }

  Future<void> _tapEl(Element? e, String what) async {
    if (!await _tap(e, what)) _fail(what);
  }

  Future<void> _tapKey(String key) async {
    if (!await _wait(() => _byKey(key) != null, '控件 $key')) _fail('控件 $key');
    await _tapEl(_byKey(key), '控件 $key');
  }

  Future<void> _tapAt(Offset pos) async {
    final binding = WidgetsBinding.instance;
    final id = _pointer++;
    binding.handlePointerEvent(PointerDownEvent(
        pointer: id, position: pos, kind: PointerDeviceKind.touch));
    await Future.delayed(const Duration(milliseconds: 70));
    binding.handlePointerEvent(PointerUpEvent(
        pointer: id, position: pos, kind: PointerDeviceKind.touch));
    await Future.delayed(const Duration(milliseconds: 300));
  }

  /// 合成一次真实拖拽（带 delta，走手势竞技场），用于块池滚动。
  Future<void> _drag(Offset from, Offset to, {int steps = 14}) async {
    final binding = WidgetsBinding.instance;
    final id = _pointer++;
    binding.handlePointerEvent(PointerDownEvent(
        pointer: id, position: from, kind: PointerDeviceKind.touch));
    var prev = from;
    for (var i = 1; i <= steps; i++) {
      final p = Offset.lerp(from, to, i / steps)!;
      binding.handlePointerEvent(PointerMoveEvent(
          pointer: id,
          position: p,
          delta: p - prev,
          kind: PointerDeviceKind.touch));
      prev = p;
      await Future.delayed(const Duration(milliseconds: 16));
    }
    binding.handlePointerEvent(PointerUpEvent(
        pointer: id, position: to, kind: PointerDeviceKind.touch));
  }

  /// 走「平台输入回调」那条路注入文本：只改 controller.value 不会触发 onChanged，
  /// 必须调 EditableTextState.updateEditingValue，才等效于真实键盘输入。
  EditableTextState? _editableState(String key) {
    final root = _byKey(key);
    if (root == null) return null;
    EditableTextState? st;
    void visit(Element e) {
      if (st != null) return;
      if (e is StatefulElement && e.state is EditableTextState) {
        st = e.state as EditableTextState;
        return;
      }
      e.visitChildren(visit);
    }

    visit(root);
    return st;
  }

  void _type(String key, String text) {
    final st = _editableState(key);
    if (st == null) throw StateError('找不到输入框 $key');
    st.updateEditingValue(TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    ));
  }

  Future<int> _typeAndMeasure(String query, bool Function() done) async {
    final sw = Stopwatch()..start();
    _type('sandboxSearch', query);
    if (!await _wait(done, '搜索「$query」过滤',
        timeout: const Duration(seconds: 6))) {
      _log('SEARCH_FAIL|want=$query|field=${_editableState('sandboxSearch')?.textEditingValue.text}');
      _fail('search');
    }
    sw.stop();
    return sw.elapsedMilliseconds;
  }

  Future<void> _reveal(String text) async {
    // 用纯查找（不做命中测试）：横向标签条里的标签可能还没滑进可视区。
    final el = _findText(text);
    if (el != null) {
      await Scrollable.ensureVisible(el,
          duration: const Duration(milliseconds: 250));
    }
  }

  /// 造资产：a0/a2 → 已掌握（串联要用），a4 → 需重修（琥珀微标要用）。
  Future<void> _seedAssets() async {
    final store = progress.chunkStore;
    Future<void> toMastered(String id) async {
      await store.applyEvent(id, ChunkEvent.assembleCorrect);
      await store.applyEvent(id, ChunkEvent.dragCorrect);
      await store.applyEvent(id, ChunkEvent.accuracyPass, accuracy: 100);
      await store.applyEvent(id, ChunkEvent.speakSuccess,
          accuracy: 100, fourStarsGreen: true, enforceFourStars: true);
      for (var i = 0; i < 4; i++) {
        await store.applyEvent(id, ChunkEvent.speakSuccess,
            accuracy: 100, review: true);
      }
    }

    await toMastered('a0');
    await toMastered('a2');
    await store.applyEvent('a4', ChunkEvent.assembleCorrect);
    await store.applyEvent('a4', ChunkEvent.dragCorrect);
    await store.applyEvent('a4', ChunkEvent.accuracyPass, accuracy: 100);
    await store.applyEvent('a4', ChunkEvent.speakSuccess, accuracy: 100);
    await store.applyEvent('a4', ChunkEvent.speakFail,
        accuracy: 0, review: true);
  }

  Future<void> run(BuildContext root) async {
    _ctx = root;
    // 屏幕高度在跨 await 之前取好：之后再碰 context 就是 use_build_context_synchronously。
    final screenH = MediaQuery.of(root).size.height;
    await progress.setAiNetOn(false);
    _check('判定走本机规则（E2E 关闭联网点评）', !progress.aiNetOn,
        'aiNetOn=${progress.aiNetOn}');
    await _seedAssets();

    final big = _sbPool(200);
    final small = _sbPool(20);

    // ① 页高恒定闸门：20 块与 200 块的三区骨架必须逐区一致。
    await _open(small);
    final sk20 = _skeleton();
    await _close();
    await _open(big);
    final sk200 = _skeleton();
    _log('SKEL|20=${sk20.map((k, v) => MapEntry(k, _fmt(v)))}');
    _log('SKEL|200=${sk200.map((k, v) => MapEntry(k, _fmt(v)))}');
    _check(
        '五个骨架区全部渲染',
        sk200.values.every((r) => r != Rect.zero) &&
            sk20.values.every((r) => r != Rect.zero),
        'keys=${sk200.keys.length}');
    final d = _diff(sk20, sk200);
    _check('页高恒定：200 块与 20 块三区骨架逐区一致', d.isEmpty, d.isEmpty ? '逐区一致' : d);

    final mic = _rect('sandboxMic');
    _check(
        'mic 固定可达（下半屏 + 完整可见）',
        mic != null && mic.bottom <= screenH && mic.top > screenH / 2,
        'mic=${_fmt(mic)} screenH=${screenH.toStringAsFixed(0)}');

    final rendered = _renderedChips();
    _check('块池虚拟化（200 块同屏渲染远小于总量）', rendered > 0 && rendered < 60,
        'rendered=$rendered/200');

    // ② 滚动：块池滚得动、其余三区不动、帧预算达标。
    final before = _skeleton();
    final pool = _rect('sandboxPool');
    if (pool == null) _fail('pool rect');
    // 先空甩两下预热：首帧要建整棵 widget 树，把冷启动开销计进帧预算没有意义。
    for (var w = 0; w < 2; w++) {
      await _drag(pool!.center, Offset(pool.center.dx, pool.center.dy - 300));
      await _pause(300);
    }
    await _pause(1200);
    _frameMs.clear();
    SchedulerBinding.instance.addTimingsCallback(_onTimings);
    var flings = 0;
    while (flings < 30 && !_hasText('say199 now')) {
      await _drag(pool!.center, Offset(pool.center.dx, pool.center.dy - 620));
      await _pause(200);
      flings++;
    }
    await _pause(600);
    SchedulerBinding.instance.removeTimingsCallback(_onTimings);
    final after = _skeleton();
    final reachedTail = _hasText('say199 now');
    final fixed = _diff(before, after);
    final worst =
        _frameMs.isEmpty ? 0 : _frameMs.reduce((a, b) => a > b ? a : b);
    _log('SCROLL|flings=$flings|frames=${_frameMs.length}|worst=${worst}ms|'
        'long50=${_frameMs.where((ms) => ms > 50).length}');
    _check('滚动只动块池：三区与池视口坐标不变', fixed.isEmpty, fixed.isEmpty ? '骨架不变' : fixed);
    _check('200 块滚到底可达', reachedTail,
        '末块可见=$reachedTail 首块仍可见=${_hasText('say0 now')}');
    _check('滚动无卡顿（帧预算）', _frameMs.length >= 20 && worst < 100,
        '帧数=${_frameMs.length} 最长=${worst}ms >50ms=${_frameMs.where((ms) => ms > 50).length}帧');

    // 重新打开：滚动位置复位，后面的搜索/筛选从干净状态开始。
    await _close();
    await _open(big);

    // ③ 搜索即时过滤（英文 + 中文释义）与需重修微标。
    final msEn = await _typeAndMeasure(
        'say199 now', () => _hasText('say199 now') && !_hasText('say0 now'));
    _check('搜索即时过滤（英文表面形态）', msEn < 500, '${msEn}ms');
    final msCn = await _typeAndMeasure(
        '释义0', () => _hasText('say0 now') && !_hasText('say1 now'));
    _check('搜索即时过滤（中文释义）', msCn < 500, '${msCn}ms');
    _type('sandboxSearch', 'say4 now');
    if (!await _wait(() => _hasText('say4 now'), '搜索结果里的 a4')) _fail('badge');
    _check('需重修块带琥珀微标', _findIcon(Icons.autorenew) != null,
        'say4 now = a4（复习失败一次）');
    _type('sandboxSearch', '');
    await _pause(250);

    // ④ 场景标签筛选。
    await _reveal('机场 · 100');
    if (!await _tapText('机场 · 100')) _fail('scene filter');
    _check('场景标签筛选只看一个场景', _hasText('say1 now') && !_hasText('say0 now'),
        '机场=b* 计数=${_firstWithPrefix('机场 · ')}');
    // 标签渲染成「名称 · 数量」，复位要按实际文案找。
    final allLabel =
        _allTexts().firstWhere((t) => t.startsWith('全部'), orElse: () => '全部');
    if (!await _tapText(allLabel)) _fail('scene reset');
    _check('切回全部场景', _hasText('say0 now'), '筛选复位');

    // ⑤ 拼句 → 开口 → 通过入库 + 串联计量。
    if (!await _tapText('say0 now')) _fail('pick a0');
    if (!await _tapText('say2 now')) _fail('pick a2');
    _check('句子卡实时显示拼好的句子', _hasText('say0 now say2 now'),
        _firstWithPrefix('say0 now say2'));
    await _tapKey('sandboxMic');
    if (!await _waitText('正在聆听… 再点一下停止')) _fail('recording start');
    await Future.delayed(const Duration(milliseconds: 1800));
    await _tapKey('sandboxMic');
    final chained = await _waitText('已存入我的句子 · 串联 +1',
        timeout: const Duration(seconds: 30));
    _check('开口通过 → 自动入库 + 串联 +1', chained,
        chained ? '反馈条文案=已存入我的句子 · 串联 +1' : failure);
    if (!await _waitText('自由造句沙盒 · 1 句')) _fail('title count');
    _check('标题计数跟着变', _hasText('自由造句沙盒 · 1 句'), _firstWithPrefix('自由造句沙盒'));

    // ⑥ 我的句子抽屉。
    await _tapKey('sandboxMySentences');
    final drawer = await _waitText('我的句子');
    _check(
        '我的句子抽屉：自动标点入库 + 重听/重录/删除齐备',
        drawer &&
            _hasText('Say0 now say2 now.') &&
            _findIcon(Icons.volume_up) != null &&
            _findIcon(Icons.mic) != null &&
            _findIcon(Icons.delete_outline) != null,
        'drawer=$drawer stored=${progress.sandbox.sentences.map((e) => e.text).join(',')}');
    await _tapAt(const Offset(20, 90));
    await _pause(600);

    // ⑦ 导出：真机文件回读，确认沙盒四项度量成段。
    await _close();
    _nav.push(MaterialPageRoute(builder: (_) => const LibraryScreen()));
    if (!await _waitText('词块资产库', timeout: const Duration(seconds: 25))) {
      _fail('library');
    }
    // 入场动画没走完就取坐标，会点到动画中途的位置（导出按钮被算到屏幕外）。
    await _pause(900);
    if (!await _tapText('导出')) _fail('export tap');
    if (!await _waitText('学习数据已生成', timeout: const Duration(seconds: 30))) {
      _fail('export dialog');
    }
    final pathEl =
        _find((w) => w is SelectableText && (w.data ?? '').contains('/data/'));
    final path =
        pathEl == null ? '' : ((pathEl.widget as SelectableText).data ?? '');
    _log('EXPORT|$path');
    var body = '';
    try {
      body = File(path).readAsStringSync();
    } catch (e) {
      _log('EXPORT_READ_FAIL|$e');
    }
    final seg = body
        .split('\n')
        .where((l) =>
            l.startsWith('五、沙盒') ||
            l.startsWith('沙盒访问') ||
            l.startsWith('句子产出') ||
            l.startsWith('串联使用') ||
            l.startsWith('搜索使用') ||
            l.startsWith('筛选使用'))
        .join(' / ');
    _log('SB_SECTION|$seg');
    _check(
        '导出含沙盒四项度量（真机文件回读）',
        body.contains('五、沙盒（自由造句）') &&
            body.contains('句子产出：1 句') &&
            body.contains('串联使用：1 次'),
        seg.isEmpty ? '未读到导出正文' : seg);
    _check('导出头部版本＝1.5.3', body.contains('版本：1.5.3'),
        body.split('\n').take(4).join(' / '));

    _log('DONE|${allPassed ? 'PASS' : 'FAIL'}|checks=${_checks.length}');
  }
}

// —— Q-3：浸泡层听→学闭环 E2E ——

/// 造数：c04 已掌握（金色、无按钮），c11 长期 14 天档（立即复习 → 升已掌握）。
/// c01 留空，走「加入学习 → 六步 → 立即复习」主链。
/// 需要全新账本（pm clear）再跑：sessions 表不能由 resetChunks 清掉。
Future<void> _seedQ3(ProgressService progress, DateTime now) async {
  await progress.chunkStore.db.resetChunks();
  final store = ChunkProgressStore(progress.chunkStore.db, clock: () => now);
  Future<void> learn(String id) async {
    await store.applyEvent(id, ChunkEvent.assembleCorrect);
    await store.applyEvent(id, ChunkEvent.dragCorrect);
    await store.applyEvent(id, ChunkEvent.accuracyPass, accuracy: 100);
    await store.applyEvent(id, ChunkEvent.speakSuccess,
        accuracy: 100, fourStarsGreen: true, enforceFourStars: true);
  }

  Future<void> review(String id) async {
    await store.applyEvent(id, ChunkEvent.speakSuccess,
        accuracy: 100, review: true);
  }

  await learn('c04');
  for (var i = 0; i < 4; i++) {
    await review('c04');
  }
  await learn('c11');
  for (var i = 0; i < 3; i++) {
    await review('c11');
  }
  await progress.clearLearnResume('listen_c01');
  await progress.clearLearnResume('listen_c11');
  await progress.clearLearnResume('review');
  await progress.listening.savePosition('L01', 0, 0);
}

Future<void> _captureRoot(String name) async {
  await Future.delayed(const Duration(milliseconds: 250));
  try {
    final ro = e2eRootKey.currentContext?.findRenderObject();
    if (ro is! RenderRepaintBoundary) return;
    final image = await ro.toImage(pixelRatio: 2);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    if (data == null) return;
    final f = File('${Directory.systemTemp.path}/q3_$name.png');
    await f.writeAsBytes(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        flush: true);
    debugPrint('E2E_Q3|SHOT|$name|${f.path}');
  } catch (e) {
    debugPrint('E2E_Q3|SHOT_FAIL|$name|$e');
  }
}

class _Q3Screen extends StatefulWidget {
  final ProgressService progress;
  final ContentPack content;
  final ListeningPack listening;
  const _Q3Screen({
    required this.progress,
    required this.content,
    required this.listening,
  });

  @override
  State<_Q3Screen> createState() => _Q3ScreenState();
}

class _Q3ScreenState extends State<_Q3Screen> {
  String _status = '准备中…';
  bool _done = false;
  bool _ok = false;
  List<String> _checks = const [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _run());
  }

  Future<void> _run() async {
    await Future.delayed(const Duration(seconds: 2));
    if (!mounted) return;
    setState(() => _status = '造数：c04 已掌握 / c11 长期 14 天档…');
    try {
      await _seedQ3(widget.progress, DateTime.now());
    } catch (e, st) {
      CrashLog.write('Q3 seed: $e', st);
      if (!mounted) return;
      setState(() {
        _done = true;
        _status = '造数失败：$e';
      });
      return;
    }
    if (!mounted) return;
    setState(() => _status = 'Q-3 闭环走查运行中…');
    final auto = _Q3Auto(
      progress: widget.progress,
      content: widget.content,
      pack: widget.listening,
    );
    var ok = false;
    try {
      ok = await auto.run(context);
    } catch (e, st) {
      CrashLog.write('Q3 run: $e', st);
      auto.failure = '异常：$e';
    }
    if (!mounted) return;
    setState(() {
      _done = true;
      _ok = ok;
      _checks = auto.checks;
      _status = ok
          ? 'Q-3 全流程 PASS（检查项见 logcat E2E_Q3）'
          : '流程中断：${auto.failure}（详见 logcat E2E_Q3）';
    });
    await Future.delayed(const Duration(milliseconds: 500));
    await _captureRoot('console');
  }

  @override
  Widget build(BuildContext context) {
    final color =
        _done ? (_ok ? kUnlocked : Colors.redAccent) : kPrimary;
    return Scaffold(
      backgroundColor: kBg,
      appBar: AppBar(title: const Text('E2E · 波 3 验收控制台')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const Text('听文章 → 收词 → 六步 → 重逢 → 立即复习 → 升档',
              style: TextStyle(color: Colors.white54)),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: kCard,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: color),
            ),
            child: Text(_status,
                style: TextStyle(
                    color: color,
                    fontSize: 16,
                    fontWeight: FontWeight.w700)),
          ),
          const SizedBox(height: 16),
          if (_checks.isNotEmpty)
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: kCard,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final c in _checks)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Text(c,
                          style: TextStyle(
                              color: c.endsWith('PASS')
                                  ? kUnlocked
                                  : Colors.redAccent,
                              fontSize: 12,
                              fontFamily: 'monospace')),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _Q3Auto with _AutoUi {
  static const _s1 = 'I am in a hurry, so I just want a coffee to go.';
  static const _s3 = 'I feel hungry, so I order a muffin as well.';
  static const _s4 = 'The barista smiles and asks what size I want.';
  static const _s6 = 'She asks if I want oat milk today.';
  static const _eventNames = [
    'article_collect',
    'candidate_wish',
    'collect_six_start',
    'collect_six_done',
    'reunion_review_start',
    'reunion_review_done',
  ];

  final ProgressService progress;
  final ContentPack content;
  final ListeningPack pack;
  final Map<String, int> _baseline = {};
  _Q3Auto({
    required this.progress,
    required this.content,
    required this.pack,
  });

  @override
  String get logTag => 'E2E_Q3';

  List<String> get checks => List.unmodifiable(_checks);

  int _eventCount(String name) =>
      progress.analyticsEvents.where((e) => e['n'] == name).length;

  int _delta(String name) => _eventCount(name) - (_baseline[name] ?? 0);

  Future<void> _shot(String name) => _captureRoot(name);

  Future<bool> run(BuildContext context) async {
    final article = pack.byId['L01'];
    if (article == null) {
      failure = '内容包缺 L01';
      _log('MISSING|L01');
      return false;
    }
    for (final n in _eventNames) {
      _baseline[n] = _eventCount(n);
    }
    _log('START|Q3|article=${article.id}');
    Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => ListeningPlayerPage(article: article)));
    if (!await _waitText('句级离线音频已就绪',
        prefix: true, timeout: const Duration(seconds: 120))) {
      return false;
    }
    await _shot('player_ready');

    // —— 金色只认已掌握：c04 预置 mastered，c11 仍是长期 ——
    final c04Gold = _spanGold(_s1, 'to go');
    final c11GoldBefore = _spanGold(_s4, 'what size');
    _check('金色·已掌握 c04', c04Gold, 'c04Gold=$c04Gold');
    _check('金色·长期 c11 未染金', !c11GoldBefore, 'c11Gold=$c11GoldBefore');

    // —— 浮层暂停 / 关闭续播 + 已掌握分派 ——
    await _tapIcon(Icons.play_arrow);
    if (!await _wait(() => _hasIconInTree(Icons.pause), '开始播放',
        timeout: const Duration(seconds: 12))) {
      return false;
    }
    await Future.delayed(const Duration(milliseconds: 700));
    if (!await _tapChunk(_s1, 'to go')) return false;
    if (!await _waitText('已完成全部复习间隔，只试听，不再排期。')) return false;
    final pausedBySheet =
        _hasIconInTree(Icons.play_arrow) && !_hasIconInTree(Icons.pause);
    _check('浮层打开暂停播放', pausedBySheet, 'paused=$pausedBySheet');
    _check('分派·已掌握',
        _hasText('已掌握') && _hasText('已掌握 · 完成全部复习间隔'),
        'badge=${_hasText('已掌握 · 完成全部复习间隔')}');
    _check('已掌握无主按钮',
        _findFilledButton('立即复习') == null &&
            _findFilledButton('继续学习') == null &&
            _findFilledButton('加入学习') == null,
        'no-primary');
    await _shot('sheet_mastered');
    if (!await _dismissSheet('已完成全部复习间隔，只试听，不再排期。')) return false;
    final resumed = await _wait(() => _hasIconInTree(Icons.pause), '自动续播',
        timeout: const Duration(seconds: 8));
    _check('浮层关闭自动续播', resumed, 'resumed=$resumed');
    if (resumed) {
      await _tapIcon(Icons.pause);
      await _wait(() => _hasIconInTree(Icons.play_arrow), '停播');
    }
    final pos = progress.listening.positionFor('L01');
    _check('续播点已落账', pos != null, 'pos=${pos?.sentenceIndex}');

    // —— 加入学习（无账本行 → 落账，不强制六步）——
    if (!await _tapChunk(_s1, 'a coffee')) return false;
    if (!await _waitText('加入后进入词块库，并排入明日复习；不强制立刻学六步。')) {
      return false;
    }
    _check('分派·加入学习',
        _hasText('未加入学习') && _findFilledButton('加入学习') != null,
        'join=${_findFilledButton('加入学习') != null}');
    _check('收词计数 0/8', _hasText('本篇已收 0/8 块'), 'cap0');
    await _shot('sheet_join');
    if (!await _tapButton('加入学习')) return false;
    if (!await _waitText('已加入词块库 · 可在词块库或再次点开本块继续六步。')) {
      return false;
    }
    _check('落账后按钮已加入待学习',
        _buttonEnabled('已加入 · 待学习') == false,
        'enabled=${_buttonEnabled('已加入 · 待学习')}');
    _check('收词计数 1/8', _hasText('本篇已收 1/8 块'), 'cap1');
    await _shot('sheet_joined');
    final c01Row = await progress.chunkStore.get('c01');
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final dueMs = c01Row.dueDate;
    final dueNextDay =
        (dueMs - (nowMs + const Duration(days: 1).inMilliseconds)).abs() <
            const Duration(minutes: 2).inMilliseconds;
    final scheduleRows =
        await progress.chunkStore.db.sessionOutcomeCounts(review: false);
    _check('落账·巩固中且次日到期',
        c01Row.assetState == ChunkAssetState.consolidating && dueNextDay,
        'state=${c01Row.assetState.name} dueIn=${((dueMs - nowMs) / 3600000).toStringAsFixed(1)}h');
    _check('落账·scheduleReview 一条',
        (scheduleRows['scheduleReview'] ?? 0) == 1,
        'scheduleReview=${scheduleRows['scheduleReview']}');
    _check('收词账本与事件',
        progress.listening.isCollected('c01') &&
            progress.listening.collectedCountFor('L01') == 1 &&
            _delta('article_collect') == 1,
        'collected=${progress.listening.isCollected('c01')} evt=${_delta('article_collect')}');

    // —— 再开浮层：继续学习（有账本、未真正走完六步）——
    if (!await _dismissSheet('已加入词块库 · 可在词块库或再次点开本块继续六步。')) {
      return false;
    }
    if (!await _tapChunk(_s1, 'a coffee')) return false;
    if (!await _waitText('已收词，继续六步可完成这块。')) return false;
    _check('分派·继续学习',
        _hasText('继续学习') && _findFilledButton('继续学习') != null,
        'continue=${_findFilledButton('继续学习') != null}');
    _check('收词计数复开 1/8', _hasText('本篇已收 1/8 块'), 'cap1b');
    await _shot('sheet_continue');
    if (!await _tapButton('继续学习')) return false;
    if (!await _waitText('收听收词 · 六步')) return false;
    if (!await _waitText('开始拆解')) return false;
    await _shot('six_anchor');
    if (!await _driveSix('a coffee')) return false;
    if (!await _waitText('六步完成 · 已回到文章，可继续听',
        timeout: const Duration(seconds: 15))) {
      return false;
    }
    await _shot('six_done');
    final row6 = await progress.chunkStore.get('c01');
    final learned = await progress.chunkStore.db
        .hasSessionOutcome('c01', 'speakSuccess', review: false);
    _check('六步后仍巩固中（不伪造已掌握）',
        row6.assetState == ChunkAssetState.consolidating,
        'state=${row6.assetState.name}');
    _check('收词漏斗·开始与完成',
        progress.listening.isSixStarted('c01') &&
            progress.listening.isConverted('c01') &&
            learned &&
            _delta('collect_six_start') == 1 &&
            _delta('collect_six_done') == 1,
        'start=${_delta('collect_six_start')} done=${_delta('collect_six_done')}');
    _check('六步后断点标记已清（不会回写成第 5 步）',
        (progress.learnResume('listen_c01') ?? '').isEmpty,
        'resume=${progress.learnResume('listen_c01')}');

    // —— 六步后分派立即复习（重逢）——
    if (!await _tapChunk(_s1, 'a coffee')) return false;
    if (!await _waitText('复习走后四步；通过后按 1/3/7/14 天档升一级。')) {
      return false;
    }
    _check('分派·六步后立即复习',
        _hasText('巩固中') && _findFilledButton('立即复习') != null,
        'reviewNow=${_findFilledButton('立即复习') != null}');
    await _shot('sheet_review_now');
    if (!await _tapButton('立即复习')) return false;
    if (!await _waitText('重逢复习')) return false;
    if (!await _waitText('听辨 · 第 1/2 轮')) return false;
    await _shot('review_start');
    if (!await _driveReview('a coffee')) return false;
    if (!await _waitText('复习通过 · 升档「已巩固」',
        prefix: true, timeout: const Duration(seconds: 20))) {
      return false;
    }
    await _shot('review_promoted');
    final rowR = await progress.chunkStore.get('c01');
    _check('复习后升档已巩固 3 天档',
        rowR.assetState == ChunkAssetState.consolidated &&
            rowR.reviewStage == 1,
        'state=${rowR.assetState.name} stage=${rowR.reviewStage}');
    _check('重逢复习事件',
        _delta('reunion_review_start') == 1 &&
            _delta('reunion_review_done') == 1,
        'start=${_delta('reunion_review_start')} done=${_delta('reunion_review_done')}');

    // —— 候选块：只记意愿，不落库 ——
    if (!await _tapChunk(_s6, 'oat milk')) return false;
    if (!await _waitText('只记录想学意愿（文章 + 块文本），不建词块、不计学习进度。')) {
      return false;
    }
    _check('分派·新块候选',
        _hasText('新块候选') && _findFilledButton('记录想学') != null,
        'wish=${_findFilledButton('记录想学') != null}');
    await _shot('sheet_candidate');
    if (!await _tapButton('记录想学')) return false;
    if (!await _waitText('已记录 · 会反哺内容排产')) return false;
    _check('候选已记录按钮置灰',
        _buttonEnabled('已记录') == false,
        'enabled=${_buttonEnabled('已记录')}');
    await _shot('sheet_wished');
    final candRow = await progress.chunkStore.db.getChunk('lx_food_oat_milk');
    final candSession = await progress.chunkStore.db
        .hasSessionOutcome('lx_food_oat_milk', 'speakSuccess');
    _check('候选不落库',
        candRow == null &&
            !candSession &&
            !progress.listening.isCollected('lx_food_oat_milk') &&
            progress.listening.wishCount('L01', 'oat milk') == 1,
        'row=${candRow != null} session=$candSession');
    _check('候选意愿事件', _delta('candidate_wish') == 1,
        'evt=${_delta('candidate_wish')}');
    if (!await _dismissSheet('只记录想学意愿（文章 + 块文本），不建词块、不计学习进度。')) {
      return false;
    }

    // —— 重逢复习到已掌握：长期 14 天档 → 金色 ——
    if (!await _revealSentence(_s4)) return false;
    _check('重逢前 c11 非金色', !_spanGold(_s4, 'what size'), 'gold=false');
    if (!await _tapChunk(_s4, 'what size')) return false;
    if (!await _waitText('复习走后四步；通过后按 1/3/7/14 天档升一级。')) {
      return false;
    }
    _check('分派·长期立即复习',
        _hasText('长期') && _findFilledButton('立即复习') != null,
        'longTerm=${_findFilledButton('立即复习') != null}');
    await _shot('sheet_longterm');
    if (!await _tapButton('立即复习')) return false;
    if (!await _waitText('听辨 · 第 1/2 轮')) return false;
    if (!await _driveReview('what size')) return false;
    if (!await _waitText('复习通过 · 升档「已掌握」',
        prefix: true, timeout: const Duration(seconds: 20))) {
      return false;
    }
    await _shot('review_mastered');
    final rowM = await progress.chunkStore.get('c11');
    _check('复习升已掌握',
        rowM.assetState == ChunkAssetState.mastered,
        'state=${rowM.assetState.name}');
    if (!await _revealSentence(_s4)) return false;
    final c11Gold = _spanGold(_s4, 'what size');
    _check('复习后金色高亮', c11Gold, 'goneGold=$c11Gold');
    await _shot('gold_after_review');
    if (!await _tapChunk(_s4, 'what size')) return false;
    if (!await _waitText('已完成全部复习间隔，只试听，不再排期。')) return false;
    _check('c11 已掌握终态无按钮',
        _hasText('已掌握 · 完成全部复习间隔') &&
            _findFilledButton('立即复习') == null,
        'badge=${_hasText('已掌握 · 完成全部复习间隔')}');
    await _shot('sheet_c11_mastered');
    if (!await _dismissSheet('已完成全部复习间隔，只试听，不再排期。')) return false;
    _check('重逢复习事件累计 2',
        _delta('reunion_review_start') == 2 &&
            _delta('reunion_review_done') == 2,
        'start=${_delta('reunion_review_start')} done=${_delta('reunion_review_done')}');
    _check('重逢计数（c04/c01/c11/复开）',
        progress.listening.totalReunions() == 4,
        'reunions=${progress.listening.totalReunions()}');

    // —— 导出：浸泡段漏斗与候选意愿 ——
    final export = await buildLearningExport(
        progress: progress, content: content, now: DateTime.now());
    final ef = File('${Directory.systemTemp.path}/q3_export.txt');
    await ef.writeAsString(export.text, flush: true);
    _log('EXPORT|${ef.path}');
    _check('导出·版本 1.5.4', export.text.contains('版本：1.5.4'), 'version');
    _check(
        '导出·浸泡段完整',
        export.text.contains('五、浸泡（磨耳朵）') &&
            export.text.contains('收词：1 块') &&
            export.text.contains('收词后开始六步：1 块') &&
            export.text.contains('收词后完成六步：1 块（推动率 100.0%）') &&
            export.text.contains('候选块想学：1 条'),
        'immersion');

    final snapshot = <String, dynamic>{
      'c01': _rowJson(await progress.chunkStore.get('c01')),
      'c04': _rowJson(await progress.chunkStore.get('c04')),
      'c11': _rowJson(await progress.chunkStore.get('c11')),
      'candidate': {
        'row': candRow != null,
        'session': candSession,
        'collected': progress.listening.isCollected('lx_food_oat_milk'),
        'wishes': progress.listening.wishCount('L01', 'oat milk'),
      },
      'ledger': {
        'collected': progress.listening.collectedIds.toList(),
        'sixStarted': progress.listening.sixStartedIds.toList(),
        'converted': progress.listening.convertedIds.toList(),
        'wishes': progress.listening.totalWishes,
        'reunions': progress.listening.totalReunions(),
      },
      'events': {for (final n in _eventNames) n: _eventCount(n)},
    };
    final sf = File('${Directory.systemTemp.path}/q3_snapshot.json');
    await sf.writeAsString(
        const JsonEncoder.withIndent('  ').convert(snapshot),
        flush: true);
    _log('SNAPSHOT|${sf.path}');

    // —— 收词上限：补 7 条账本到 8/8，验证置灰与文案（导出已先行取证）——
    for (var i = 0; i < 7; i++) {
      await progress.listening.markCollected('q3_cap_$i', 'L01');
    }
    if (!await _tapChunk(_s3, 'feel hungry')) return false;
    if (!await _waitText('本篇已收 8/8 块，达到上限；先把已收的块学完，明天再收。')) {
      return false;
    }
    _check('收词上限置灰',
        _hasText('本篇已收 8/8 块') && _buttonEnabled('加入学习') == false,
        'cap=${progress.listening.collectedCountFor('L01')}');
    await _shot('sheet_cap');
    if (!await _dismissSheet('本篇已收 8/8 块，达到上限；先把已收的块学完，明天再收。')) {
      return false;
    }

    _log('DONE|${allPassed ? 'PASS' : 'FAIL'}|checks=${_checks.length}');
    if (allPassed && context.mounted) Navigator.of(context).pop();
    return allPassed;
  }

  Map<String, dynamic>? _rowJson(ChunkRow? r) => r == null
      ? null
      : {
          'state': r.assetState.name,
          'stage': r.reviewStage,
          'due': r.dueDate,
          'level': r.level.name,
          'reviewCount': r.reviewCount,
          'correctStreak': r.correctStreak,
          'firstLearnedAt': r.firstLearnedAt,
        };

  // —— 六步 / 复习：真实控件驱动（识别结果由脚本注入）——

  Future<bool> _driveSix(String chunkText) async {
    if (!await _waitText('开始拆解')) return false;
    await Future.delayed(const Duration(milliseconds: 1200));
    if (!await _tapText('开始拆解')) return false;
    if (!await _waitText('把词块拆开看', prefix: true)) return false;
    for (final w
        in chunkText.split(RegExp(r'\s+')).where((x) => x.isNotEmpty)) {
      if (!await _tapText(w)) return false;
    }
    if (!await _waitText('拆完了，拼回去它就长在你嘴里')) return false;
    if (!await _tapText('拼回去 · 去听辨')) return false;
    if (!await _listenRounds(3, chunkText)) return false;
    if (!await _speakOnce(
        micWaitText: '影子跟读', nextText: '第 5/6 步 · 定向替换')) {
      return false;
    }
    if (!await _substitute(nextText: '第 6/6 步 · 自由造句')) return false;
    if (!await _waitText('第 6/6 步 · 自由造句')) return false;
    if (!await _tapText('说出来')) return false;
    if (!await _waitText('说完点这里')) return false;
    await Future.delayed(const Duration(milliseconds: 2500));
    if (!await _tapText('说完点这里')) return false;
    if (!await _waitText('完成这一块', timeout: const Duration(seconds: 30))) {
      return false;
    }
    if (!await _tapText('完成这一块')) return false;
    if (!await _waitText('本块完成', timeout: const Duration(seconds: 8))) {
      return false;
    }
    return true;
  }

  Future<bool> _driveReview(String chunkText) async {
    if (!await _listenRounds(2, chunkText)) return false;
    if (!await _speakOnce(
        micWaitText: '复习·跟读', nextText: '复习 · 定向替换')) {
      return false;
    }
    if (!await _substitute(nextText: '复习·开口')) return false;
    if (!await _waitText('复习·开口', prefix: true)) return false;
    if (!await _tapIcon(Icons.mic)) return false;
    if (!await _waitText('正在录音', prefix: true)) return false;
    await Future.delayed(const Duration(milliseconds: 2500));
    if (!await _tapIcon(Icons.stop)) return false;
    return true;
  }

  Future<bool> _listenRounds(int total, String chunkText) async {
    for (var r = 1; r <= total; r++) {
      if (!await _waitText('听辨 · 第 $r/$total 轮')) return false;
      await Future.delayed(const Duration(milliseconds: 400));
      if (!await _tapText(chunkText)) return false;
      if (!await _waitText('这轮听对了！')) return false;
      final next = r < total ? '下一轮' : '完成听辨';
      if (!await _tapText(next, prefix: true)) return false;
    }
    return true;
  }

  Future<bool> _speakOnce(
      {required String micWaitText, required String nextText}) async {
    if (!await _waitText(micWaitText, prefix: true)) return false;
    if (!await _tapIcon(Icons.mic)) return false;
    if (!await _waitText('正在录音', prefix: true)) return false;
    await Future.delayed(const Duration(milliseconds: 2500));
    if (!await _tapIcon(Icons.stop)) return false;
    if (!await _waitText(nextText, timeout: const Duration(seconds: 30))) {
      return false;
    }
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
    return true;
  }

  // —— 句子/词块定位与浮层操作 ——

  Element? _findSentenceEl(String sentence) => _find((w) {
        if (w is! Text) return false;
        final span = w.textSpan;
        return span != null && span.toPlainText() == sentence;
      });

  ScrollableState? _verticalScrollable() {
    ScrollableState? hit;
    void visit(Element e) {
      if (hit != null) return;
      final w = e.widget;
      if (w is Scrollable &&
          (w.axisDirection == AxisDirection.down ||
              w.axisDirection == AxisDirection.up)) {
        if (ModalRoute.of(e)?.isCurrent == true) {
          hit = (e as StatefulElement).state as ScrollableState;
          return;
        }
      }
      e.visitChildren(visit);
    }

    final root = WidgetsBinding.instance.rootElement;
    if (root != null) visit(root);
    return hit;
  }

  Future<bool> _revealSentence(String sentence) async {
    var el = _findSentenceEl(sentence);
    if (el == null) {
      final st = _verticalScrollable();
      if (st == null) {
        failure = '找不到句子滚动区';
        _log('MISSING|scrollable');
        return false;
      }
      final pos = st.position;
      if (!await _wait(() => pos.hasContentDimensions, '句子列表布局',
          timeout: const Duration(seconds: 6))) {
        return false;
      }
      pos.jumpTo(0);
      await Future.delayed(const Duration(milliseconds: 120));
      el = _findSentenceEl(sentence);
      var offset = 0.0;
      for (var i = 0; i < 40 && el == null; i++) {
        if (offset >= pos.maxScrollExtent) break;
        offset = (offset + 220).clamp(0.0, pos.maxScrollExtent);
        pos.jumpTo(offset);
        await Future.delayed(const Duration(milliseconds: 80));
        el = _findSentenceEl(sentence);
      }
    }
    if (el == null) return false;
    await Scrollable.ensureVisible(el,
        alignment: 0.45, duration: const Duration(milliseconds: 220));
    await Future.delayed(const Duration(milliseconds: 350));
    return true;
  }

  Future<bool> _tapChunk(String sentence, String chunkText) async {
    if (!await _revealSentence(sentence)) {
      failure = '找不到句子：$sentence';
      _log('MISSING|sentence|$sentence');
      return false;
    }
    final el = _findSentenceEl(sentence);
    final ro = el?.renderObject;
    if (el == null || ro is! RenderParagraph) {
      failure = '句子未渲染成段落：$sentence';
      _log('MISSING|paragraph|$sentence');
      return false;
    }
    final start = sentence.toLowerCase().indexOf(chunkText.toLowerCase());
    if (start < 0) {
      failure = '句内找不到词块：$chunkText';
      return false;
    }
    final boxes = ro.getBoxesForSelection(
        TextSelection(baseOffset: start, extentOffset: start + chunkText.length));
    if (boxes.isEmpty) {
      failure = '词块无文字盒：$chunkText';
      _log('MISSING|boxes|$chunkText');
      return false;
    }
    final pos = ro.localToGlobal(boxes.first.toRect().center);
    final size = MediaQuery.of(el).size;
    if (pos.dx < 0 || pos.dy < 0 || pos.dy > size.height) {
      failure = '词块不在屏幕内：$chunkText';
      _log('OFFSCREEN|$chunkText|$pos');
      return false;
    }
    await _tapAt(pos, '词块「$chunkText」');
    return true;
  }

  bool _spanGold(String sentence, String chunkText) {
    final el = _findSentenceEl(sentence);
    if (el == null) return false;
    final root = (el.widget as Text).textSpan;
    var found = false;
    root?.visitChildren((span) {
      if (span is TextSpan && span.text == chunkText) {
        final style = span.style;
        if (style?.color == kListeningMasteredText &&
            style?.backgroundColor == kListeningMasteredBg) {
          found = true;
        }
      }
      return !found;
    });
    return found;
  }

  bool _hasIconInTree(IconData icon) =>
      _find((w) => w is Icon && w.icon == icon) != null;

  bool _subtreeHasText(Element e, String text) {
    var hit = false;
    void visit(Element x) {
      if (hit) return;
      final w = x.widget;
      if (w is Text && w.data == text) {
        hit = true;
        return;
      }
      x.visitChildren(visit);
    }

    visit(e);
    return hit;
  }

  Element? _findFilledButton(String label) {
    final matches = <Element>[];
    void visit(Element e) {
      if (e.widget is FilledButton && _subtreeHasText(e, label)) {
        matches.add(e);
      }
      e.visitChildren(visit);
    }

    final root = WidgetsBinding.instance.rootElement;
    if (root != null) visit(root);
    for (final e in matches.reversed) {
      final ro = e.renderObject;
      if (ro is! RenderBox || !ro.attached || ro.size.isEmpty) continue;
      final pos = ro.localToGlobal(ro.size.center(Offset.zero));
      final result = HitTestResult();
      WidgetsBinding.instance.hitTestInView(result, pos, View.of(e).viewId);
      if (result.path.any((entry) => entry.target == ro)) return e;
    }
    return matches.isEmpty ? null : matches.last;
  }

  bool? _buttonEnabled(String label) {
    final e = _findFilledButton(label);
    if (e == null) return null;
    return (e.widget as FilledButton).onPressed != null;
  }

  Future<bool> _tapButton(String label) async {
    Element? b;
    final ok = await _wait(() {
      b = _findFilledButton(label);
      return b != null;
    }, '按钮「$label」', timeout: const Duration(seconds: 8));
    if (!ok) return false;
    return _tap(b, '按钮「$label」');
  }

  Future<void> _tapAt(Offset pos, String what) async {
    final binding = WidgetsBinding.instance;
    final id = _pointer++;
    binding.handlePointerEvent(PointerDownEvent(
        pointer: id, position: pos, kind: PointerDeviceKind.touch));
    await Future.delayed(const Duration(milliseconds: 70));
    binding.handlePointerEvent(PointerUpEvent(
        pointer: id, position: pos, kind: PointerDeviceKind.touch));
    _log('TAP|$what|${pos.dx.toStringAsFixed(0)},${pos.dy.toStringAsFixed(0)}');
    await Future.delayed(const Duration(milliseconds: 400));
  }

  Future<bool> _dismissSheet(String marker) async {
    await _tapAt(const Offset(20, 80), '浮层遮罩');
    if (!await _wait(() => !_hasText(marker), '浮层关闭',
        timeout: const Duration(seconds: 6))) {
      return false;
    }
    await Future.delayed(const Duration(milliseconds: 250));
    return true;
  }
}
