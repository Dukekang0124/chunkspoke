import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chunkspoke_flutter/services/recording.dart';

/// §拾音-分享（最小形态）的落点测试：
/// 只分享最近一次留存的那份录音，且必须先复制到 cache/share/ 再叫系统面板
/// （FileProvider 只暴露这个子目录）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const pathCh = MethodChannel('plugins.flutter.io/path_provider');
  const recCh = MethodChannel('chunkspoke/recorder');

  late Directory root;
  late Directory docs;
  late Directory cache;
  late List<MethodCall> calls;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('share_rec_');
    docs = Directory('${root.path}/docs')..createSync(recursive: true);
    cache = Directory('${root.path}/cache')..createSync(recursive: true);
    calls = [];

    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(pathCh, (call) async {
      switch (call.method) {
        case 'getApplicationDocumentsDirectory':
          return docs.path;
        case 'getTemporaryDirectory':
          return cache.path;
      }
      return null;
    });
    messenger.setMockMethodCallHandler(recCh, (call) async {
      calls.add(call);
      if (call.method == 'share') return null;
      return null;
    });

    RecordingService.lastDebugWavPath = null;
  });

  tearDown(() async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(pathCh, null);
    messenger.setMockMethodCallHandler(recCh, null);
    RecordingService.lastDebugWavPath = null;
    if (await root.exists()) await root.delete(recursive: true);
  });

  test('没有留存录音：不叫系统面板，返回 false', () async {
    final ok = await RecordingService.shareLast();
    expect(ok, isFalse);
    expect(calls.where((c) => c.method == 'share'), isEmpty);
  });

  test('只分享最近一次：复制到 cache/share/recording.wav 再走系统面板', () async {
    final src = File('${docs.path}/asr_debug/last.wav');
    src.parent.createSync(recursive: true);
    src.writeAsBytesSync(List<int>.generate(64, (i) => i));
    RecordingService.lastDebugWavPath = src.path;

    final ok = await RecordingService.shareLast();
    expect(ok, isTrue);

    final share = calls.singleWhere((c) => c.method == 'share');
    final args = Map<String, dynamic>.from(share.arguments as Map);
    final path = args['path'] as String;
    expect(path, endsWith('/share/recording.wav'));
    expect(path.startsWith(cache.path), isTrue);
    expect(args['text'], RecordingService.kShareText);

    final copied = File(path);
    expect(await copied.exists(), isTrue);
    expect(await copied.readAsBytes(), await src.readAsBytes());
  });

  test('进程内路径失效时回落到文档 asr_debug/last.wav', () async {
    final src = File('${docs.path}/asr_debug/last.wav');
    src.parent.createSync(recursive: true);
    src.writeAsBytesSync([1, 2, 3]);
    // 指向一个已经不存在的旧路径：不许拿它去分享。
    RecordingService.lastDebugWavPath = '${root.path}/gone.wav';

    final ok = await RecordingService.shareLast();
    expect(ok, isTrue);

    final share = calls.singleWhere((c) => c.method == 'share');
    final args = Map<String, dynamic>.from(share.arguments as Map);
    expect(File(args['path'] as String).existsSync(), isTrue);
  });
}
