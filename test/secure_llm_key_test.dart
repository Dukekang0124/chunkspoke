import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_common_ffi.dart';
import 'package:chunkspoke_flutter/services/database.dart';
import 'package:chunkspoke_flutter/services/loaders.dart';
import 'package:chunkspoke_flutter/services/llm_provider.dart';
import 'package:chunkspoke_flutter/services/secure_store.dart';
import 'support/fake_key_cipher.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('自定义模型 Key：Keystore 密文存储（B-3）', () {
    late AppDatabase db;
    setUp(() {
      // 同库跨实例：模拟杀进程后重启读回。
      db = AppDatabase(path: inMemoryDatabasePath);
    });

    Future<ProgressService> boot({KeyCipher? cipher}) async {
      final p = ProgressService(db: db, cipher: cipher ?? FakeKeyCipher());
      await p.init();
      return p;
    }

    test('写入即密文：落库不含明文，内存 getter 仍是明文', () async {
      final p = await boot();
      await p.setCustomLlmKey('sk-plain-123');
      final raw = await db.getKv('customLlmKey');
      expect(raw, isNotNull);
      expect(raw!.startsWith(kEncPrefix), isTrue);
      expect(raw.contains('sk-plain-123'), isFalse);
      expect(p.customLlmKey, 'sk-plain-123');
    });

    test('重启后从密文解回明文，resolveActive 拿到正确 Key', () async {
      final p1 = await boot();
      await p1.setCustomLlmEnabled(true);
      await p1.setCustomLlmUrl('https://x.example/v1');
      await p1.setCustomLlmModel('m1');
      await p1.setCustomLlmKey('sk-restart');

      final p2 = await boot();
      expect(p2.customLlmKey, 'sk-restart');
      final cfg = LlmProvider(p2).resolveActive();
      expect(cfg, isNotNull);
      expect(cfg!.key, 'sk-restart');
    });

    test('历史明文一次性迁移：init 后磁盘变密文，读回不丢', () async {
      await db.setKv('customLlmKey', 'sk-legacy-456');
      final cipher = FakeKeyCipher();
      final p = await boot(cipher: cipher);
      expect(p.customLlmKey, 'sk-legacy-456');
      expect(cipher.encryptCount, 1);
      final raw = await db.getKv('customLlmKey');
      expect(raw!.startsWith(kEncPrefix), isTrue);
      expect(raw.contains('sk-legacy-456'), isFalse);
      // 已是密文时不重复加密。
      await boot(cipher: cipher);
      expect(cipher.encryptCount, 1);
    });

    test('解密失败（Keystore 密钥失效）→ Key 为空，AI 不联网', () async {
      final p1 = await boot();
      await p1.setCustomLlmEnabled(true);
      await p1.setCustomLlmKey('sk-lost');

      final broken = FakeKeyCipher()..failDecrypt = true;
      final p2 = await boot(cipher: broken);
      expect(p2.customLlmKey, isNull);
      expect(LlmProvider(p2).resolveActive(), isNull);
    });

    test('清除配置 → Key 置空且磁盘不留密文', () async {
      final p = await boot();
      await p.setCustomLlmKey('sk-clear');
      await p.clearCustomLlm();
      expect(p.customLlmKey, isNull);
      expect(await db.getKv('customLlmKey'), '');
    });
  });
}
