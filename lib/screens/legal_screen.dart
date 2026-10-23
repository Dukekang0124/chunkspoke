import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import '../ui/theme.dart';

/// GPLv3 全文与源码获取要约：eSpeak NG 数据及 APK 内静态链接代码的合规入口。
class LegalScreen extends StatelessWidget {
  const LegalScreen({super.key});

  Future<List<String>> _load() => Future.wait([
        rootBundle.loadString('assets/legal/LICENSE-GPLv3.txt'),
        rootBundle.loadString('assets/legal/SOURCE-OFFER.txt'),
        rootBundle.loadString('assets/legal/VOICE-PACK-NOTICE.txt'),
      ]);

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        backgroundColor: kBg,
        appBar: AppBar(
          title: const Text('开源许可与源码'),
          bottom: const TabBar(
            indicatorColor: kPrimary,
            labelColor: kText,
            unselectedLabelColor: Colors.white54,
            tabs: [
              Tab(text: 'GPLv3 全文'),
              Tab(text: '源码要约'),
              Tab(text: '组件声明'),
            ],
          ),
        ),
        body: FutureBuilder<List<String>>(
          future: _load(),
          builder: (context, snap) {
            if (snap.hasError) {
              return const Center(
                child: Text('许可文本读取失败，请重新打开',
                    style: TextStyle(color: Colors.white54)),
              );
            }
            final data = snap.data;
            if (data == null) {
              return const Center(child: CircularProgressIndicator());
            }
            return TabBarView(
              children: [
                _textPage(data[0]),
                _textPage(data[1]),
                _textPage(data[2]),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _textPage(String text) => SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: SelectableText(
          text,
          style: const TextStyle(
              color: Colors.white70, fontSize: 12, height: 1.5),
        ),
      );
}
