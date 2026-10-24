import 'dart:io';

import 'package:chunkspoke_flutter/services/database.dart';
import 'package:chunkspoke_flutter/services/loaders.dart';
import 'package:chunkspoke_flutter/ui/badge_count.dart';
import 'package:chunkspoke_flutter/ui/confetti.dart';
import 'package:chunkspoke_flutter/ui/count_up.dart';
import 'package:chunkspoke_flutter/ui/motion.dart';
import 'package:chunkspoke_flutter/ui/permission_preprompt.dart';
import 'package:chunkspoke_flutter/ui/play_pause_morph.dart';
import 'package:chunkspoke_flutter/ui/pressable.dart';
import 'package:chunkspoke_flutter/ui/stagger.dart';
import 'package:chunkspoke_flutter/ui/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:sqflite_common_ffi/sqflite_common_ffi.dart';

/// 指令 M · 动效波单测：闸门逻辑、降级行为与红线条款中可机器核验的部分。
const Key kConfettiLayer = ValueKey('confetti-layer');
const Key kMorphLayer = ValueKey('play-pause-morph');

Widget _host(Widget child,
        {bool reduce = false,
        bool lowPower = false,
        ProgressService? progress}) =>
    MultiProvider(
      providers: [
        ChangeNotifierProvider<MotionService>(
            create: (_) => _StubMotion(lowPower)),
        if (progress != null) Provider<ProgressService>.value(value: progress),
      ],
      child: MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(disableAnimations: reduce),
          child: Scaffold(body: child),
        ),
      ),
    );

/// 省电状态由测试直接给定，不碰原生 PowerManager。
class _StubMotion extends MotionService {
  _StubMotion(this._low) : super(powerProbe: () async => false);
  final bool _low;
  @override
  bool get lowPower => _low;
}

String _mastered(int v) => '已掌握 $v 个词块';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('MotionPolicy 闸（M1 基建）', () {
    test('未降级时按时长跑，降级时一律直接切换', () {
      const on = MotionPolicy();
      expect(on.dur(200), const Duration(milliseconds: 200));
      expect(on.animates, isTrue);
      for (final p in const [
        MotionPolicy(reduceMotion: true),
        MotionPolicy(lowPower: true),
      ]) {
        expect(p.dur(200), Duration.zero);
        expect(p.animates, isFalse, reason: '降级即直接切换，不放动画');
      }
    });

    test('减弱动画关撒花，省电只减半粒子', () {
      expect(const MotionPolicy(reduceMotion: true).confettiOn, isFalse);
      expect(const MotionPolicy(lowPower: true).confettiOn, isTrue,
          reason: '省电仍允许庆祝，但粒子减半');
      expect(const MotionPolicy(lowPower: true).particles(60), 30);
      expect(const MotionPolicy().particles(60), 60);
    });

    test('触感闸：省电关震动，其余放行（7 处 HapticFeedback 统一走这里）', () {
      var fired = 0;
      const MotionPolicy().haptic(() => fired++);
      expect(fired, 1);
      const MotionPolicy(lowPower: true).haptic(() => fired++);
      expect(fired, 1, reason: '省电模式不得再震');
    });

    testWidgets('无 MotionService 的宿主（兜底页/局部 pump）退回只看系统设置',
        (tester) async {
      late MotionPolicy seen;
      await tester.pumpWidget(MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: Builder(builder: (ctx) {
            seen = Motion.of(ctx);
            return const SizedBox.shrink();
          }),
        ),
      ));
      expect(seen.reduceMotion, isTrue);
      expect(seen.lowPower, isFalse);
    });
  });

  group('MotionService 省电探测', () {
    test('启动探测为省电时置位', () async {
      final svc = MotionService(powerProbe: () async => true);
      await Future<void>.delayed(Duration.zero);
      expect(svc.lowPower, isTrue);
      svc.dispose();
    });

    test('探测抛异常按非省电处理，不影响动效', () async {
      final svc = MotionService(
          powerProbe: () async => throw Exception('no channel'));
      await Future<void>.delayed(Duration.zero);
      expect(svc.lowPower, isFalse);
      svc.dispose();
    });
  });

  group('撒花共享组件（#25 / R1 氛围层）', () {
    testWidgets('减弱动画开启时整段不放，并在下一帧回调 onDone', (tester) async {
      var done = 0;
      await tester.pumpWidget(_host(
        ConfettiBurst(onDone: () => done++),
        reduce: true,
      ));
      await tester.pump();
      expect(find.byKey(kConfettiLayer), findsNothing);
      expect(done, 1, reason: '降级时调用方仍要收到「播完」信号以收掉覆盖层');
    });

    testWidgets('正常态绘制彩带粒子', (tester) async {
      await tester.pumpWidget(_host(const ConfettiBurst()));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byKey(kConfettiLayer), findsOneWidget);
    });

    testWidgets('省电态粒子减半仍会绘制', (tester) async {
      await tester.pumpWidget(_host(const ConfettiBurst(), lowPower: true));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byKey(kConfettiLayer), findsOneWidget);
    });
  });

  group('数字滚动（P0-5）', () {
    testWidgets('降级时直接显示终值文案', (tester) async {
      await tester.pumpWidget(_host(
        const CountUpText(10, format: _mastered),
        reduce: true,
      ));
      expect(find.text('已掌握 10 个词块'), findsOneWidget);
    });

    testWidgets('正常态从 0 滚到终值，动画结束后落到终值', (tester) async {
      await tester.pumpWidget(_host(const CountUpText(10)));
      await tester.pump();
      expect(find.text('0'), findsOneWidget, reason: '首帧从 0 起滚');
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('10'), findsNothing, reason: '中途不得直接跳终值');
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('10'), findsOneWidget);
    });
  });

  group('播放暂停变形（#38）', () {
    testWidgets('降级时退回静态图标，不做变形', (tester) async {
      await tester.pumpWidget(
          _host(const PlayPauseMorph(playing: false), reduce: true));
      expect(find.byIcon(Icons.play_arrow), findsOneWidget);
      expect(find.byKey(kMorphLayer), findsNothing);
    });

    testWidgets('正常态用绘制做顶点插值', (tester) async {
      await tester.pumpWidget(_host(const PlayPauseMorph(playing: false)));
      await tester.pump();
      expect(find.byKey(kMorphLayer), findsOneWidget);
      expect(find.byIcon(Icons.play_arrow), findsNothing);
    });
  });

  group('按下态（动效底线「有反馈」）', () {
    testWidgets('按住时缩到 0.97、松手回弹，点击回调只触发一次', (tester) async {
      var taps = 0;
      await tester.pumpWidget(_host(PressableScale(
        onTap: () => taps++,
        child: const SizedBox(
            width: 60, height: 60, child: ColoredBox(color: Colors.blue)),
      )));
      double scaleOf() =>
          tester.widget<AnimatedScale>(find.byType(AnimatedScale).first).scale;
      expect(scaleOf(), 1.0);

      final gesture =
          await tester.startGesture(tester.getCenter(find.byType(PressableScale)));
      await tester.pump();
      expect(scaleOf(), 0.97, reason: '规范 0.96–0.98');
      await gesture.up();
      await tester.pump();
      expect(scaleOf(), 1.0);
      expect(taps, 1);
    });

    testWidgets('降级时不缩放但点击仍生效', (tester) async {
      var taps = 0;
      await tester.pumpWidget(_host(
        PressableScale(
          onTap: () => taps++,
          child: const SizedBox(
              width: 60, height: 60, child: ColoredBox(color: Colors.blue)),
        ),
        reduce: true,
      ));
      await tester.tap(find.byType(PressableScale));
      await tester.pump();
      expect(taps, 1);
      expect(
          tester
              .widget<AnimatedScale>(find.byType(AnimatedScale).first)
              .duration,
          Duration.zero);
    });
  });

  group('按下态覆盖面（M-2 高频面，展示态不骗人）', () {
    testWidgets('词块 chip：展示态按下无反馈，可交互态缩到 0.96', (tester) async {
      await tester.pumpWidget(_host(Column(children: const [
        ChunkTile('看一眼', 'content'),
        ChunkTile('点一下', 'content', interactive: true),
      ])));
      List<double> scales() =>
          tester.widgetList<AnimatedScale>(find.byType(AnimatedScale)).map((s) => s.scale).toList();
      expect(scales(), [1.0, 1.0]);

      final show =
          await tester.startGesture(tester.getCenter(find.text('看一眼')));
      await tester.pump();
      expect(scales()[0], 1.0, reason: '不可点的展示芯片不能给按下反馈');
      await show.up();
      await tester.pump();

      final hit =
          await tester.startGesture(tester.getCenter(find.text('点一下')));
      await tester.pump();
      expect(scales()[1], 0.96);
      await hit.up();
      await tester.pump();
    });
  });

  group('列表入场 stagger（M-2 三处：首页播单 / 词块库分组 / 复习列表）', () {
    double _opacity(WidgetTester tester, Key key) => tester
        .widget<FadeTransition>(find
            .descendant(of: find.byKey(key), matching: find.byType(FadeTransition)))
        .opacity
        .value;

    testWidgets('降级时零 stagger：不挂淡入，子项直接显示', (tester) async {
      await tester.pumpWidget(_host(
        StaggerIn(
            key: const Key('s'),
            index: 3,
            child: const SizedBox(width: 40, height: 40)),
        reduce: true,
      ));
      expect(find.descendant(
          of: find.byKey(const Key('s')), matching: find.byType(FadeTransition)), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pump(const Duration(milliseconds: 600));
    });

    testWidgets('按序号递进：前项先亮、后项仍全透明，收尾都到 1', (tester) async {
      await tester.pumpWidget(_host(Column(children: [
        StaggerIn(
            key: const Key('s0'),
            index: 0,
            child: const SizedBox(width: 40, height: 40)),
        StaggerIn(
            key: const Key('s3'),
            index: 3,
            child: const SizedBox(width: 40, height: 40)),
      ])));
      await tester.pump(const Duration(milliseconds: 100));
      expect(_opacity(tester, const Key('s0')), greaterThan(0.0));
      expect(_opacity(tester, const Key('s3')), 0.0, reason: '第 4 项 120ms 后才起步');
      await tester.pump(const Duration(milliseconds: 600));
      expect(_opacity(tester, const Key('s0')), 1.0);
      expect(_opacity(tester, const Key('s3')), 1.0);
    });

    testWidgets('步长夹在 30–60ms（总时长仍 ≤700ms）', (tester) async {
      await tester.pumpWidget(_host(Row(children: [
        StaggerIn(
            key: const Key('low'),
            index: 1,
            stepMs: 10,
            child: const SizedBox(width: 40, height: 40)),
        StaggerIn(
            key: const Key('high'),
            index: 1,
            stepMs: 200,
            child: const SizedBox(width: 40, height: 40)),
      ])));
      // stepMs=10 → 夹到 30：20ms 时仍在延迟段内。
      await tester.pump(const Duration(milliseconds: 20));
      expect(_opacity(tester, const Key('low')), 0.0);
      // stepMs=200 → 夹到 60：100ms 时已起步（未夹会等到 200ms）。
      await tester.pump(const Duration(milliseconds: 80));
      expect(_opacity(tester, const Key('high')), greaterThan(0.0));
      await tester.pump(const Duration(milliseconds: 400));
    });

    testWidgets('长列表尾部不排队过久：超出 maxSteps 后不再累加', (tester) async {
      await tester.pumpWidget(_host(StaggerIn(
          key: const Key('tail'),
          index: 99,
          child: const SizedBox(width: 40, height: 40))));
      await tester.pump(const Duration(milliseconds: 380));
      expect(_opacity(tester, const Key('tail')), 0.0, reason: '400ms 起步（10 步封顶）');
      await tester.pump(const Duration(milliseconds: 320));
      expect(_opacity(tester, const Key('tail')), 1.0);
    });
  });

  group('到期角标（#58）', () {
    testWidgets('一位数显示数字、超 99 显示 99+、清零走缩小淡出', (tester) async {
      Widget wrap(int n) =>
          _host(BadgeCount(count: n, child: const Icon(Icons.headphones)));
      await tester.pumpWidget(wrap(3));
      await tester.pump();
      expect(find.text('3'), findsOneWidget);

      await tester.pumpWidget(wrap(120));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('99+'), findsOneWidget);

      await tester.pumpWidget(wrap(0));
      await tester.pump(const Duration(milliseconds: 60));
      final opacity =
          tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity).first);
      expect(opacity.opacity, 0.0);
      expect(opacity.duration, const Duration(milliseconds: 220),
          reason: '清零要有 220ms 淡出，不能一下消失');
    });
  });

  group('权限前说明（#64）', () {
    testWidgets('首次弹说明卡；点「以后再说」不索取权限，且下次不再弹', (tester) async {
      await tester.binding.setSurfaceSize(const Size(600, 1200));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      var requested = 0;

      // 「说明过」要落 SQLite（真实 I/O），整段跑 runAsync。
      await tester.runAsync(() async {
        final dir = await Directory.systemTemp.createTemp('m_preprompt');
        final progress =
            ProgressService(db: AppDatabase(path: '${dir.path}/t.db'));
        await progress.init();

        // runAsync 下没有 pumpAndSettle：手动推进假时钟，等入场动画落位再点。
        Future<void> settleMs(int ms) async {
          for (var i = 0; i < ms ~/ 20; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 20));
            await tester.pump(const Duration(milliseconds: 20));
          }
        }

        Future<void> tapGoAndSettle() async {
          await tester.pumpWidget(_host(
            progress: progress,
            Builder(
              builder: (ctx) => TextButton(
                onPressed: () async {
                  final ok = await permissionPrepromptConsent(ctx,
                      kind: PermissionKind.microphone);
                  if (ok) requested++;
                },
                child: const Text('go'),
              ),
            ),
          ));
          await tester.tap(find.text('go'));
          for (var i = 0; i < 60; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 20));
            await tester.pump(const Duration(milliseconds: 20));
            if (find.text('开口练习要用麦克风').evaluate().isNotEmpty ||
                requested > 0) {
              break;
            }
          }
          await settleMs(600); // 等浮层弹簧入场落位，否则点在屏幕外
        }

        await tapGoAndSettle();
        expect(find.text('开口练习要用麦克风'), findsOneWidget,
            reason: '系统权限框之前必须先讲清用途');
        expect(find.text('以后再说'), findsOneWidget);
        await tester.tap(find.text('以后再说'));
        for (var i = 0; i < 60; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
          await tester.pump(const Duration(milliseconds: 20));
          if (find.text('开口练习要用麦克风').evaluate().isEmpty) break;
        }
        await settleMs(400);
        expect(requested, 0, reason: '用户拒绝就不该弹系统框');
        expect(progress.prepromptSeenMic, isTrue);

        // 第二次：说明过就不再拦路，直接放行去请求。
        await tapGoAndSettle();
        expect(find.text('开口练习要用麦克风'), findsNothing);
        expect(requested, 1);
      });
    });
  });
}
