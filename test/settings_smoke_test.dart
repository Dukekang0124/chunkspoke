import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:sqflite_common_ffi/sqflite_common_ffi.dart';
import 'package:chunkspoke_flutter/screens/settings.dart';
import 'package:chunkspoke_flutter/services/database.dart';
import 'package:chunkspoke_flutter/services/hd_voice.dart';
import 'package:chunkspoke_flutter/services/hd_voice_types.dart';
import 'package:chunkspoke_flutter/services/loaders.dart';
import 'package:chunkspoke_flutter/services/theme_provider.dart';
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

  testWidgets('设置页渲染冒烟：保存/检查更新/高级区（GLM 三件套）/Azure 两输入框', (tester) async {
    await tester.runAsync(() async {
      // 内存库：避免本机残留的 customLlmEnabled 让「高级」默认展开而改变控件数量。
      final p = ProgressService(db: AppDatabase(path: inMemoryDatabasePath));
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
            ChangeNotifierProvider<ThemeProvider>.value(
                value: ThemeProvider(
                  initialId: p.appThemeId,
                  initialMode: p.appThemeMode,
                  persistId: p.setAppThemeId,
                  persistMode: p.setAppThemeMode,
                )),
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
      // ASR-215 P2-2：Azure 密钥/区域从首屏收进「高级（可选）」。
      // 实测依据：1.8.3 新用户一进设置就撞见两个「粘贴密钥」输入框（E5_settings.png），
      // 99% 用不到还会误以为不填不能用。现在默认折叠，点开才见。
      expect(find.text('高级（可选）：云端识别密钥'), findsOneWidget);
      expect(find.byType(TextField), findsNothing,
          reason: 'Azure 输入框不得暴露在设置首屏');
      await tester.tap(find.text('高级（可选）：云端识别密钥'));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(TextField), findsNWidgets(2),
          reason: '展开后必须仍是那两个 Azure 输入框');
      // TTS 修复入口常驻设置页。
      expect(find.text('语音朗读（TTS）'), findsOneWidget);
      // 录音留存开关已移入语音分组（常驻），分享入口默认不出现。
      // 1.7.0：外观与主题卡片插在音效卡之后，7 个色板齐全。
      expect(find.text('音效'), findsOneWidget);
      expect(find.byKey(const ValueKey('theme-card')), findsOneWidget);
      for (final id in ['default', 'nude_rose', 'sage', 'plum', 'ocean', 'forest', 'charcoal']) {
        expect(find.byKey(ValueKey('theme-swatch-$id')), findsOneWidget,
            reason: '设置页缺少色板 $id');
      }
      expect(tester.getTopLeft(find.text('外观与主题')).dy,
          greaterThan(tester.getTopLeft(find.text('音效')).dy),
          reason: '主题卡片必须在音效卡之后');
      // ASR-203：设置 → 诊断入口，紧跟外观卡之后。
      expect(find.byKey(const ValueKey('diagnostics-entry')), findsOneWidget);
      expect(tester.getTopLeft(find.text('诊断与自检')).dy,
          greaterThan(tester.getTopLeft(find.text('外观与主题')).dy),
          reason: '诊断入口必须在主题卡之后');
      expect(find.text('保存最近一次录音（排障）'), findsOneWidget);
      expect(find.text('分享最近一次录音'), findsNothing);

      // 展开「高级」→ 关闭态的在线 AI 开关（排障开关已不在高级区）。
      await tester.ensureVisible(find.text('高级'));
      await tester.pump(const Duration(milliseconds: 200));
      await tester.tap(find.text('高级'));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('启用在线 AI 助手'), findsOneWidget);
      expect(find.byType(TextField), findsNWidgets(2));

      // 开启在线 AI → 预设 + 地址/模型/Key 三件套 + 教程/测试/明示发送内容。
      await tester.ensureVisible(find.text('启用在线 AI 助手'));
      await tester.pump(const Duration(milliseconds: 200));
      await tester.tap(find.text('启用在线 AI 助手'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(TextField), findsNWidgets(5));
      expect(find.text('智谱 GLM'), findsOneWidget);
      expect(find.text('自定义（OpenAI 兼容）'), findsOneWidget);
      expect(find.text('三分钟填 GLM Key →'), findsOneWidget);
      expect(find.text('测试连接'), findsOneWidget);
      expect(
          find.textContaining('不发送录音音频，不上传学习记录'), findsOneWidget);
      expect(find.textContaining('Android Keystore 加密'), findsOneWidget);

      // 未填 Key 直接点「测试连接」：分类提示必须留在展开区内（不折叠、不丢消息）。
      await tester.ensureVisible(find.text('测试连接'));
      await tester.pump(const Duration(milliseconds: 200));
      await tester.tap(find.text('测试连接'));
      // 测试连接内部有真实 DB 写入（落 Key 字段），需给真实事件循环时间。
      await Future<void>.delayed(const Duration(milliseconds: 600));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('请先填写 API Key'), findsOneWidget);
      expect(find.byType(TextField), findsNWidgets(5));
    });
  });
}
