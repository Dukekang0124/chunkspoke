import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'models/content_pack.dart';
import 'services/loaders.dart';
import 'ui/theme.dart';
import 'screens/ftue.dart';
import 'screens/map.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final progress = ProgressService();
  await progress.init();
  await progress.bumpStreak();
  final content = await loadContentPack();
  final tts = TtsService();
  await tts.init();

  runApp(
    MultiProvider(
      providers: [
        Provider<ProgressService>.value(value: progress),
        Provider<ContentPack>.value(value: content),
        Provider<TtsService>.value(value: tts),
      ],
      child: const ChunkSpokeApp(),
    ),
  );
}

class ChunkSpokeApp extends StatelessWidget {
  const ChunkSpokeApp({super.key});

  @override
  Widget build(BuildContext context) {
    final progress = Provider.of<ProgressService>(context, listen: false);
    return MaterialApp(
      title: 'ChunkSpoke',
      debugShowCheckedModeBanner: false,
      theme: darkTheme,
      home: progress.seenFtue ? const MapScreen() : const FtueScreen(),
    );
  }
}
