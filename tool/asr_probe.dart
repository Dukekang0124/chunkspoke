// 调试探针（不进生产包）：对同一段 WAV 分别跑「窄词表」与「全模型」解码，
// 打 VOSK_RAW 原始 JSON 到 logcat，供 B5 取证对比。
import 'package:flutter/material.dart';

import 'package:chunkspoke_flutter/services/vosk_engine.dart';

const String _modelPath =
    '/data/user/0/com.chunkspoke.app/app_flutter/models/vosk-model-small-en-us-0.15';
const String _target = "I'll get a coffee.";
const String _chunk = 'a coffee';

const List<(String, String)> _cases = [
  ('pizza', '/data/user/0/com.chunkspoke.app/files/probe_pizza.wav'),
  ('coffee', '/data/user/0/com.chunkspoke.app/files/probe_coffee.wav'),
  ('chinese', '/data/user/0/com.chunkspoke.app/files/probe_chinese.wav'),
];

void main() => runApp(const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: _ProbePage(),
    ));

class _ProbePage extends StatefulWidget {
  const _ProbePage();

  @override
  State<_ProbePage> createState() => _ProbePageState();
}

class _ProbePageState extends State<_ProbePage> {
  List<String> _lines = ['准备中…'];

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    final t = VoskTranscriber();
    final ok = await t.loadModel(_modelPath);
    final out = <String>[
      'model_loaded=$ok',
      'target=$_target',
      'chunk=$_chunk',
    ];
    if (ok) {
      for (final c in _cases) {
        final narrow = await t.transcribe(c.$2, [_target, _chunk]);
        final free = await t.transcribeFree(c.$2);
        out.add('[${c.$1}] narrow="${narrow.text}" conf=${narrow.confidence}');
        out.add('[${c.$1}] free="${free.text}" conf=${free.confidence}');
      }
    }
    for (final l in out) {
      debugPrint('ASR_PROBE|$l');
    }
    if (mounted) setState(() => _lines = out);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: const Color(0xFF101018),
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('ASR 取证探针（窄词表 vs 全模型）',
                      style: TextStyle(
                          color: Colors.amber,
                          fontSize: 18,
                          fontWeight: FontWeight.w700)),
                  const SizedBox(height: 12),
                  for (final l in _lines)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Text(l,
                          style: const TextStyle(
                              color: Colors.white, fontSize: 14, height: 1.35)),
                    ),
                ],
              ),
            ),
          ),
        ),
      );
}
