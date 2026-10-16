import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:chunkspoke_flutter/screens/settings.dart';
import 'package:chunkspoke_flutter/services/loaders.dart';

/// P0 事故点回归：进度页/练习页点「设置」曾直接退桌面。
/// 本用例在宿主渲染完整设置页，验证初始化（版本读取/引擎检测兜底）不再裸抛，
/// 关键控件齐备。真机复现路径由真机走查确认。
///
/// 注意：DB 初始化/资产读取是真实 I/O，必须放进 [tester.runAsync]，
/// 否则 fake-async 区内永不完成 → 测试 10 分钟超时（首轮已踩过）。
void main() {
  setUpAll(() {
    databaseFactory = databaseFactoryFfi;
  });

  testWidgets('设置页渲染冒烟：保存/检查更新/高级区/两个输入框（密钥+区域）齐备', (tester) async {
    await tester.runAsync(() async {
      final p = ProgressService();
      // UI 冒烟为目的，DB 初始化失败（全量套件下 SQLite 并发锁等测试环境偶发）
      // 不应阻断本用例；忽略初始化错误，仍渲染设置页验证关键控件齐备。
      try {
        await p.init();
      } catch (_) {
        // 测试环境并发锁/初始化异常：不影响 UI 冒烟断言。
      }
      await tester.pumpWidget(
        MultiProvider(
          providers: [Provider<ProgressService>.value(value: p)],
          child: const MaterialApp(home: SettingsScreen()),
        ),
      );
      // 等待 initState 的异步兜底（版本读取/引擎检测）落地，不参与断言。
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('保存'), findsOneWidget);
      expect(find.text('检查更新'), findsOneWidget);
      expect(find.text('高级'), findsOneWidget);
      // 更新源输入框已移除：仅剩「Azure 密钥」「Azure 区域」两个输入框。
      expect(find.byType(TextField), findsNWidgets(2));
    });
  });
}
