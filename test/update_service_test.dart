import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:chunkspoke_flutter/services/update/update_service.dart';
import 'package:chunkspoke_flutter/services/update/version_compare.dart';
import 'package:chunkspoke_flutter/services/update/sha256_util.dart';

void main() {
  group('versionCode 比较（数值，禁止字符串）', () {
    test('远端更高 → 更新', () => expect(isNewerVersion(2018, 2019), isTrue));
    test('相等 → 不更新', () => expect(isNewerVersion(2019, 2019), isFalse));
    test('远端更低 → 不更新', () => expect(isNewerVersion(2019, 2018), isFalse));
    test('字符串型 versionCode 亦按数值比较',
        () => expect(parseVersionCode('2019'), 2019));
  });

  group('sha256 校验', () {
    test('精确匹配', () => expect(sha256Matches('abc', 'abc'), isTrue));
    test('空期望 → 跳过（通过）',
        () => expect(sha256Matches('whatever', ''), isTrue));
  });

  group('本地缓存包完整性 sizeMatches', () {
    test('大小精确匹配 → 可用', () => expect(sizeMatches(100, 100), isTrue));
    test('大小不符（不完整）→ 不可用', () => expect(sizeMatches(90, 100), isFalse));
    test('期望大小未知(0) → 非空即可用', () => expect(sizeMatches(123, 0), isTrue));
    test('期望未知且为空文件 → 不可用', () => expect(sizeMatches(0, 0), isFalse));
  });

  group('check() 三态（mock HTTP）', () {
    final cur = VersionInfo(
        versionName: '1.2.3', versionCode: 2018, url: '', sha256: '', size: 0, notes: '');
    const latestJson =
        '{"versionName":"1.2.4","versionCode":2019,"url":"https://x/a.apk","sha256":"abc","size":100,"notes":"n"}';
    const sameJson =
        '{"versionName":"1.2.3","versionCode":2017,"url":"","sha256":"","size":0,"notes":""}';

    test('远端更高 → update（弹窗）', () async {
      final svc = UpdateService();
      final client = MockClient((_) async => http.Response(latestJson, 200));
      final res = await svc.check(
          overrideUrl: 'https://x/version.json', client: client, current: cur);
      expect(res.status, CheckStatus.update);
      expect(res.info.versionCode, 2019);
    });

    test('远端不更高 → latest（已最新）', () async {
      final svc = UpdateService();
      final client = MockClient((_) async => http.Response(sameJson, 200));
      final res = await svc.check(
          overrideUrl: 'https://x/version.json', client: client, current: cur);
      expect(res.status, CheckStatus.latest);
    });

    test('非 200 → error（检查失败）', () async {
      final svc = UpdateService();
      final client = MockClient((_) async => http.Response('', 500));
      final res = await svc.check(
          overrideUrl: 'https://x/version.json', client: client, current: cur);
      expect(res.status, CheckStatus.error);
    });

    test('网络异常 → error（检查失败，不崩）', () async {
      final svc = UpdateService();
      final client = MockClient((_) async => throw Exception('no net'));
      final res = await svc.check(
          overrideUrl: 'https://x/version.json', client: client, current: cur);
      expect(res.status, CheckStatus.error);
    });

    test('占位/空 URL → error（不假装已最新）', () async {
      final svc = UpdateService();
      final res = await svc.check(
          overrideUrl: 'https://raw.githubusercontent.com/OWNER/REPO/main/version.json',
          current: cur);
      expect(res.status, CheckStatus.error);
    });
  });
}
