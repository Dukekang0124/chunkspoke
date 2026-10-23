// 发音审计工具（不随包发布）：枚举系统 TTS 声音、分级导出、逐档合成试听。
// 运行：flutter run -d <device> -t tool/tts_audit.dart
// 产物：<external files>/tts_audit/voices.json + *.wav + measurements.json
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'package:chunkspoke_flutter/services/tts_voice.dart';

const String kSentence = "I'd like a cup of coffee.";
const int kWords = 6;
const String kCalSentence =
    "I would like a cup of coffee and a piece of cake, please.";
const int kCalWords = 14;

void main() {
  runApp(const MaterialApp(
    home: Scaffold(
      backgroundColor: Colors.black,
      body: Center(
        child: Text('TTS 审计中…', style: TextStyle(color: Colors.white)),
      ),
    ),
  ));
  _runAudit();
}

Future<Directory> _outDir() async {
  final base = await getExternalStorageDirectory();
  final dir = Directory(p.join(base!.path, 'tts_audit'));
  if (!await dir.exists()) await dir.create(recursive: true);
  return dir;
}

Future<void> _log(Directory dir, String s) async {
  debugPrint('[audit] $s');
  try {
    await File(p.join(dir.path, 'audit.log')).writeAsString(
      '${DateTime.now().toIso8601String()} $s\n',
      mode: FileMode.append,
    );
  } catch (_) {}
}

Future<int> _fileLen(File f) async {
  try {
    return await f.exists() ? await f.length() : 0;
  } catch (_) {
    return 0;
  }
}

/// 轮询合成产物：文件非空且连续 3 次长度不变视为完成。
Future<int> _waitFile(File f, {Duration timeout = const Duration(seconds: 45)}) async {
  final end = DateTime.now().add(timeout);
  var stable = 0;
  var last = -1;
  while (DateTime.now().isBefore(end)) {
    await Future<void>.delayed(const Duration(milliseconds: 300));
    final len = await _fileLen(f);
    if (len > 44 && len == last) {
      if (++stable >= 3) return len;
    } else {
      stable = 0;
    }
    last = len;
  }
  return await _fileLen(f);
}

/// 读取 WAV 头得到时长（秒）。Google TTS 输出 16-bit PCM 单声道。
double? _wavSeconds(Uint8List b) {
  if (b.length < 44) return null;
  final data = ByteData.sublistView(b);
  if (String.fromCharCodes(b.sublist(0, 4)) != 'RIFF') return null;
  if (String.fromCharCodes(b.sublist(8, 12)) != 'WAVE') return null;
  var off = 12;
  int? byteRate;
  int? dataSize;
  while (off + 8 <= b.length) {
    final id = String.fromCharCodes(b.sublist(off, off + 4));
    final size = data.getUint32(off + 4, Endian.little);
    if (id == 'fmt ') {
      byteRate = data.getUint32(off + 16, Endian.little);
    } else if (id == 'data') {
      dataSize = size;
      break;
    }
    off += 8 + size + (size.isOdd ? 1 : 0);
  }
  if (byteRate == null || byteRate == 0 || dataSize == null) return null;
  return dataSize / byteRate;
}

Future<void> _runAudit() async {
  final dir = await _outDir();
  final tts = FlutterTts();
  try {
    await _log(dir, 'output=${dir.path}');
    final defaultEngine = await tts.getDefaultEngine;
    final engines = (await tts.getEngines)?.cast<String>() ?? <String>[];
    final order = <String>[
      if (defaultEngine != null) defaultEngine,
      ...engines.where((e) => e != defaultEngine),
    ];
    await _log(dir, 'defaultEngine=$defaultEngine engines=$engines');

    await tts.setLanguage('en-US');
    await tts.setSpeechRate(0.9);
    await tts.setPitch(1.0);
    await tts.awaitSynthCompletion(true);

    final raw = (await tts.getVoices) as List? ?? const [];
    final voices = <Map<String, String>>[];
    for (final v in raw) {
      if (v is Map) {
        voices.add({
          for (final e in v.entries) '${e.key}': '${e.value}',
        });
      }
    }
    final parsed = [
      for (final m in voices) TtsVoice.fromMap(m, engine: defaultEngine ?? ''),
    ];
    final ranked = rankTtsVoices(parsed, engineOrder: order);

    await File(p.join(dir.path, 'voices.json')).writeAsString(
      const JsonEncoder.withIndent('  ').convert({
        'device': Platform.operatingSystemVersion,
        'defaultEngine': defaultEngine,
        'engines': engines,
        'total': voices.length,
        'ranked': [
          for (final v in ranked)
            {
              'name': v.name,
              'locale': v.locale,
              'quality': v.quality,
              'latency': v.latency,
              'networkRequired': v.networkRequired,
              'installed': v.installed,
              'score': v.autoScore,
              'label': v.label,
            }
        ],
        'all': voices,
      }),
    );
    await _log(dir, 'voices=${voices.length} ranked=${ranked.length}');

    final picks = <String, TtsVoice>{};
    if (ranked.isNotEmpty) {
      picks['auto_top'] = ranked.first;
      for (final v in ranked) {
        if (!v.networkRequired) {
          picks['local'] = v;
          if (v.name.endsWith('-local')) break;
        }
      }
      for (final v in ranked) {
        if (!v.networkRequired && v.name.endsWith('-local')) {
          picks['local_voice'] = v;
          break;
        }
      }
      final low = ranked.where((v) => v.qualityRank <= 2).toList();
      if (low.isNotEmpty) picks['lower_tier'] = low.first;
      if (ranked.length > 1) picks['auto_second'] = ranked[1];
    }
    await _log(dir, 'picks=${picks.map((k, v) => MapEntry(k, v.key))}');

    final results = <String, dynamic>{};
    for (final entry in picks.entries) {
      final tag = entry.key;
      final v = entry.value;
      await tts.setVoice({'name': v.name, 'locale': v.locale});
      await tts.setSpeechRate(0.22);
      final f = File(p.join(dir.path, 'audition_$tag.wav'));
      if (await f.exists()) await f.delete();
      await tts.synthesizeToFile(kSentence, f.path, true);
      final len = await _waitFile(f, timeout: const Duration(seconds: 8));
      final sec = len > 44 ? _wavSeconds(await f.readAsBytes()) : null;
      results[tag] = {
        'voice': v.key,
        'label': v.label,
        'bytes': len,
        'seconds': sec,
        'wpm': sec == null ? null : (kWords / sec * 60).toStringAsFixed(1),
      };
      await _log(dir, '$tag -> ${v.key} bytes=$len sec=$sec');
    }

    // 语速标定：同一声音、同一句，比较 0.8 / 0.9 / 1.0 / 1.1。
    final cal = picks['auto_top'];
    if (cal != null) {
      await tts.setVoice({'name': cal.name, 'locale': cal.locale});
      for (final rate in [0.2, 0.22, 0.25]) {
        await tts.setSpeechRate(rate);
        final f = File(p.join(dir.path, 'rate_${(rate * 100).round()}.wav'));
        if (await f.exists()) await f.delete();
        await tts.synthesizeToFile(kCalSentence, f.path, true);
        final len = await _waitFile(f, timeout: const Duration(seconds: 8));
        final sec = len > 44 ? _wavSeconds(await f.readAsBytes()) : null;
        results['rate_${(rate * 100).round()}'] = {
          'rate': rate,
          'bytes': len,
          'seconds': sec,
          'wpm': sec == null ? null : (kCalWords / sec * 60).toStringAsFixed(1),
        };
        await _log(dir, 'rate=$rate bytes=$len sec=$sec');
      }
    }

    await File(p.join(dir.path, 'measurements.json'))
        .writeAsString(const JsonEncoder.withIndent('  ').convert(results));
    await _log(dir, 'DONE');
  } catch (e, st) {
    await _log(dir, 'FATAL $e\n$st');
  }
}
