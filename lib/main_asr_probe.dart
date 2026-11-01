// ASR-191 探针入口（不参与生产包，与 main_e2e.dart 同性质）。
//
// 在 Android 模拟器上走一遍**真实生产代码**：
//   清单 → 下载（自家 ModelManager：分片+sha256+解压）→ 常驻 isolate 加载 →
//   静音/噪声/合成语音识别 → 关闭释放 → 再开启（不重下）。
// 结果写到 `<ASRCHECK_DIR>/report.txt`，同时 debugPrint 到 logcat（tag: ASRPROBE）。
//
// 用法：
//   flutter build apk --debug --target=lib/main_asr_probe.dart \
//     --target-platform android-x64 \
//     --dart-define=ASR_MODEL_BASE_URL=http://10.0.2.2:8899 \
//     --dart-define=ASRCHECK_DIR=/sdcard/Android/data/com.chunkspoke.app/files/asrcheck
import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';

import 'services/zipformer_asr.dart';

const _dir = String.fromEnvironment('ASRCHECK_DIR',
    defaultValue: '/sdcard/Android/data/com.chunkspoke.app/files/asrcheck');

final _lines = <String>[];
var _failed = 0;

void _log(String s) {
  _lines.add(s);
  debugPrint('ASRPROBE $s');
}

void _check(String name, bool ok, [String detail = '']) {
  if (!ok) _failed++;
  _log('${ok ? 'PASS' : 'FAIL'} $name${detail.isEmpty ? '' : ' | $detail'}');
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const SizedBox.shrink());
  unawaited(_run());
}

Future<void> _run() async {
  final sw = Stopwatch()..start();
  final svc = EnhancedAsrService.instance;
  try {
    await svc.refresh();
    _check('清单可读', svc.manifest != null,
        'size=${svc.manifest?.size} label=${svc.modelSizeLabel}');
    _check('清单体积=38312950', svc.manifest?.size == 38312950);

    final okDownload = await svc.downloadAndEnable();
    _check('自家管道能下+能加载', okDownload,
        'err=${svc.lastError} installed=${svc.installed} ready=${svc.ready} '
        '${sw.elapsedMilliseconds}ms');
    if (!okDownload) throw StateError('download failed: ${svc.lastError}');

    final silence = await svc.transcribeOpen('$_dir/silence.wav');
    _check('静音不出字（P0）', silence != null && silence.text.trim().isEmpty,
        'text="${silence?.text}"');

    final noise = await svc.transcribeOpen('$_dir/noise.wav');
    final nt = (noise?.text ?? '').toLowerCase();
    final hit = ['coffee', 'order', 'think', 'idea', 'again']
        .where(nt.contains)
        .toList();
    _check('噪声不命中目标句（P0）', silence != null && hit.isEmpty,
        'text="${noise?.text}" hits=$hit');

    for (final name in ['speech0', 'speech1', 'speech2', 'speech3', 'speech4']) {
      final r = await svc.transcribeOpen('$_dir/$name.wav');
      _log('INFO $name → "${r?.text}"');
    }
    final mixed = await svc.transcribeOpen('$_dir/speech0_noise.wav');
    _log('INFO speech0_noise → "${mixed?.text}"');

    final off = await svc.setEnabled(false);
    _check('可切回默认（释放后端）', off && !svc.ready && !svc.enabled);

    final t0 = Stopwatch()..start();
    final on = await svc.setEnabled(true);
    _check('再次开启不重下', on && svc.ready && t0.elapsedMilliseconds < 60000,
        '${t0.elapsedMilliseconds}ms');
    final again = await svc.transcribeOpen('$_dir/speech0.wav');
    _check('切回后仍可识别', (again?.text ?? '').toLowerCase().contains('coffee'),
        'text="${again?.text}"');

    _check('无崩溃（探针跑完）', true);
  } catch (e, st) {
    _check('异常中断', false, '$e\n$st');
  } finally {
    try {
      final f = File('$_dir/report.txt');
      await f.parent.create(recursive: true);
      await f.writeAsString(
          'ASR-191 探针 ${DateTime.now().toIso8601String()}\n'
          '${_lines.join('\n')}\n'
          'RESULT=${_failed == 0 ? 'OK' : 'FAIL($_failed)'}\n');
    } catch (e) {
      debugPrint('ASRPROBE write report failed: $e');
    }
    _log('RESULT=${_failed == 0 ? 'OK' : 'FAIL'}');
    await Future<void>.delayed(const Duration(seconds: 1));
    exit(_failed == 0 ? 0 : 1);
  }
}
