import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/content_pack.dart';
import '../services/loaders.dart';
import '../ui/theme.dart';
import 'settings.dart';

class MeScreen extends StatelessWidget {
  const MeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final progress = Provider.of<ProgressService>(context);
    final content = Provider.of<ContentPack>(context);
    final chunks = progress.chunksMastered(content);
    final streak = progress.streak;
    final hintRate = progress.sayCount + progress.hintCount > 0
        ? (progress.hintCount / (progress.hintCount + progress.sayCount) * 100).round()
        : 0;
    final acc = progress.avgScore.round();

    return Scaffold(
      appBar: AppBar(title: const Text('Me')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _stat('Chunks mastered', '$chunks'),
          _stat('Day streak', '$streak', 'Consecutive days'),
          _stat('Chinese hint rate', '$hintRate%', 'Lower is better'),
          _stat('Accuracy average', '$acc', 'Text Match / PA score'),
          const SizedBox(height: 20),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: kPrimary),
              onPressed: () => Navigator.of(context)
                  .push(MaterialPageRoute(builder: (_) => const SettingsScreen())),
              child: const Text('Settings', style: TextStyle(color: Colors.white)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _stat(String label, String value, [String sub = '']) => Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: const Color(0xFF1A1A2E),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label, style: const TextStyle(color: Colors.white70, fontSize: 14)),
                  if (sub.isNotEmpty)
                    Text(sub, style: const TextStyle(color: Colors.white38, fontSize: 11)),
                ],
              ),
            ),
            Text(value,
                style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold)),
          ],
        ),
      );
}
