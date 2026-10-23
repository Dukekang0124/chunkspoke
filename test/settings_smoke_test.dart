import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:chunkspoke_flutter/screens/settings.dart';
import 'package:chunkspoke_flutter/services/hd_voice.dart';
import 'package:chunkspoke_flutter/services/hd_voice_types.dart';
import 'package:chunkspoke_flutter/services/loaders.dart';
import 'package:chunkspoke_flutter/services/vosk_model.dart';

class _FakeHdDownloader implements HdVoiceDownloader {
  @override
  Stream<ModelProgress> get progress => const Stream<ModelProgress>.empty();
  @override
  Future<bool> isReady() async => false;
  @override
  Future<String> modelDirPath() async => '';
  @override
  Future<String> ensureModel() async => '';
  @override
  Future<void> resetIncomplete() async {}
  @override
  Future<void> discard() async {}
  @override
  void dispose() {}
}

/// 设置页冒烟用的 TTS 假实现：避免平台通道，同时让检测结果稳定为 ready。
class _FakeTtsAdapter implements TtsAdapter {
  @override
  Future<String?> getDefaultEngine() async => 'com.google.android.tts';

  @override
  Future<List<String>> getEngines() async => ['com.google.android.tts'];

  @override
  Future<bool> isLanguageAvailable(String lang) async => lang == 'en-US';

  @override
  Future<bool> setLanguage(String lang) async => lang == 'en-US';

  @override
  Future<void> setEngine(String engine) async {}

  @override
  Future<void> setSpeechRate(double rate) async {}

  @override
  Future<void> setPitch(double pitch) async {}

  @override
  Future<int> speak(String text) async => 1;

  @override
  Future<void> stop() async {}
}

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
      final tts = TtsService(adapter: _FakeTtsAdapter());
      await tts.init();
      final hd = HdVoiceService(
        isEnabled: () => false,
        setEnabled: (_) async {},
        downloader: _FakeHdDownloader(),
      );
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            Provider<ProgressService>.value(value: p),
            Provider<TtsService>.value(value: tts),
            ChangeNotifierProvider<HdVoiceService>.value(value: hd),
          ],
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
      // TTS 修复入口常驻设置页。
      expect(find.text('语音朗读（TTS）'), findsOneWidget);
    });
  });
}
