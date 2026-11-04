import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:sqflite_common_ffi/sqflite_common_ffi.dart';

import 'package:chunkspoke_flutter/models/content_pack.dart';
import 'package:chunkspoke_flutter/screens/level.dart';
import 'package:chunkspoke_flutter/screens/license_activate.dart';
import 'package:chunkspoke_flutter/services/database.dart';
import 'package:chunkspoke_flutter/services/license_state.dart';
import 'package:chunkspoke_flutter/services/session_report.dart';

/// 1.8.1（任务书：商业化转化链路）· 墙点 → 加微信 → 复制 → 激活 的链路回归。
///
/// 钉死四件事：
///  1. 墙上先讲清价格与名额（¥68 / 原价 ¥128 / 前 200 名），再给两个出口；
///  2. 购买说明里的微信号 = kz910124，且「复制」真的写进剪贴板；
///  3. 「我已有码」仍走输码页（转化不能把老路径堵死）；
///  4. 结算页横幅只在「免费区最后一关已达标 + 未激活」出现，PRO/老用户一律不出现。
void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  const wechatSheetEntry = '加微信购买';

  /// 手机尺寸：默认 800×600 测试面会把整张 sheet 挤到溢出（真机也不会这么矮）。
  Future<void> phone(WidgetTester tester) async =>
      tester.binding.setSurfaceSize(const Size(360, 780));

  Future<void> openWall(WidgetTester tester) async {
    await phone(tester);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (ctx) => Center(
            child: ElevatedButton(
              onPressed: () => showLicenseWallSheet(ctx,
                  title: '这一关要解锁码', detail: 'G 关起的内容需要解锁码。'),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('墙点 sheet：价格行 + 两个出口 + 不骚扰的三级按钮', (tester) async {
    await openWall(tester);
    expect(find.text('¥$kEarlyBirdPrice'), findsOneWidget,
        reason: '早鸟价必须写在墙上，不能只写「输入解锁码」');
    expect(find.text('原价 ¥$kStandardPrice'), findsOneWidget);
    expect(find.text('前 $kEarlyBirdSeats 名 · 永久买断'), findsOneWidget);
    expect(find.textContaining(wechatSheetEntry), findsOneWidget);
    expect(find.text('我已有码，输入激活'), findsOneWidget);
    expect(find.text('先继续学生存 S0 + A–F'), findsOneWidget,
        reason: '1.8.0 起免费区含生存 S0，文案不能只说 A–F');
  });

  testWidgets('点「加微信购买」→ 购买说明显示微信号 kz910124', (tester) async {
    await openWall(tester);
    await tester.tap(find.textContaining(wechatSheetEntry));
    await tester.pumpAndSettle();
    expect(find.text('如何获取解锁码'), findsOneWidget);
    expect(find.text(kWechatId), findsOneWidget);
    expect(kWechatId, 'kz910124', reason: '任务书 §〇：微信号写死，不做配置化');
    expect(find.textContaining('搜微信号 $kWechatId'), findsOneWidget);
    expect(find.text('我知道了'), findsOneWidget);
  });

  testWidgets('点「复制」→ 剪贴板收到微信号并提示', (tester) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String;
        }
        return null;
      },
    );
    await openWall(tester);
    await tester.tap(find.textContaining(wechatSheetEntry));
    await tester.pumpAndSettle();
    await tester.tap(find.text('复制'));
    await tester.pump();
    expect(copied, kWechatId, reason: '复制的必须是微信号本体，不带前后缀');
    expect(find.text('微信号已复制，去微信粘贴添加吧'), findsOneWidget);
    // 纯复制微信号，不嵌二维码图片（任务书 §六.8）。
    expect(find.byType(Image), findsNothing);
  });

  testWidgets('点「我已有码」→ 进输码页（老路径不被转化堵死）', (tester) async {
    await phone(tester);
    // sqflite FFI 走真实后台 isolate，fake-async 里 await 会永久挂住 → 必须 runAsync。
    late AppDatabase db;
    late LicenseState lic;
    await tester.runAsync(() async {
      db = AppDatabase(path: inMemoryDatabasePath);
      await db.db;
      lic = LicenseState(db: db, legacyEligible: false, secrets: ['0' * 64]);
      await lic.load();
    });
    await tester.pumpWidget(ChangeNotifierProvider<LicenseState?>.value(
      value: lic,
      child: MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => Center(
              child: ElevatedButton(
                onPressed: () => showLicenseWallSheet(ctx,
                    title: '这一关要解锁码', detail: 'G 关起的内容需要解锁码。'),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('我已有码，输入激活'));
    await tester.pumpAndSettle();
    expect(find.text('输入解锁码'), findsWidgets, reason: 'AppBar 标题 = 输码页已到达');
    expect(find.byType(TextField), findsOneWidget);
    expect(find.textContaining(wechatSheetEntry), findsNothing);
    await tester.runAsync(() async => (await db.db).close());
  });

  // ——— 结算页横幅（任务书 §五 / 验收 7·8·9）———
  final fLevel = Level(
    id: 'F',
    theme: 'Shopping',
    sceneImage: '',
    chunks: [
      Chunk.fromJson(
          {'id': 'f01', 'text': 'how much', 'type': 'content', 'meaningCN': '多少钱'})
    ],
  );

  Future<void> pumpCompletion(WidgetTester tester,
      {required bool freeTierDone, required bool hasFullAccess}) async {
    await phone(tester);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: CompletionView(
          level: fLevel,
          dims: const [true, true, true, true],
          report: const SessionReport(
              newMastered: 5, spoken: 6, maxCombo: 5, completed: 5, starChunks: 4),
          nextReview: '11月5日',
          freeTierDone: freeTierDone,
          hasFullAccess: hasFullAccess,
          freeChunks: 167,
          totalChunks: 517,
        ),
      ),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
  }

  testWidgets('学完免费区最后一关且未激活 → 出横幅，数字取内容包实时值', (tester) async {
    await pumpCompletion(tester, freeTierDone: true, hasFullAccess: false);
    expect(find.text('🎉 你已完成全部免费内容'), findsOneWidget);
    expect(find.textContaining('167/517 块'), findsOneWidget,
        reason: '1.8.0 起免费口径是 生存 S0 + A–F = 167 块，不能再写 137/487');
    expect(find.textContaining('还有 350 块等你解锁'), findsOneWidget);
    expect(find.text('了解详情'), findsOneWidget);
  });

  testWidgets('已激活 PRO / 老用户 → 横幅不出现', (tester) async {
    await pumpCompletion(tester, freeTierDone: true, hasFullAccess: true);
    expect(find.text('🎉 你已完成全部免费内容'), findsNothing);
  });

  testWidgets('本关没达标（免费区未走完）→ 横幅不出现', (tester) async {
    await pumpCompletion(tester, freeTierDone: false, hasFullAccess: false);
    expect(find.text('🎉 你已完成全部免费内容'), findsNothing);
  });

  testWidgets('点横幅「了解详情」→ 弹购买说明（与墙上同一入口）', (tester) async {
    await pumpCompletion(tester, freeTierDone: true, hasFullAccess: false);
    await tester.tap(find.text('了解详情'));
    await tester.pumpAndSettle();
    expect(find.text('如何获取解锁码'), findsOneWidget);
    expect(find.text(kWechatId), findsOneWidget);
  });
}
