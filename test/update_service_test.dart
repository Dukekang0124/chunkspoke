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
          overrideUrl:
              'https://raw.githubusercontent.com/OWNER/REPO/main/version.json',
          current: cur);
      expect(res.status, CheckStatus.error);
    });
  });

  group('下载进度总量（对齐弹窗显示，缺失 Content-Length 也能出进度）', () {
    test('version.json 有 size → 始终以它为准',
        () => expect(
            resolveDownloadTotal(
                expectedSize: 100,
                contentLength: 60,
                resumedBytes: 40,
                partial: true),
            100));
    test('无 size + 206 续传 → 起点 + 剩余',
        () => expect(
            resolveDownloadTotal(
                expectedSize: 0,
                contentLength: 60,
                resumedBytes: 40,
                partial: true),
            100));
    test('无 size + 200 → 取响应长度',
        () => expect(
            resolveDownloadTotal(
                expectedSize: 0,
                contentLength: 60,
                resumedBytes: 0,
                partial: false),
            60));
    test('既无 size 又无 Content-Length → 0（进度退化为未知）',
        () => expect(
            resolveDownloadTotal(
                expectedSize: 0,
                contentLength: 0,
                resumedBytes: 0,
                partial: false),
            0));
  });

  group('多下载源（主直链 + 备用源）', () {
    test('去空、去重、保持顺序', () {
      expect(
          buildDownloadUrls([
            'https://a.apk',
            '',
            null,
            'https://b.apk',
            'https://a.apk',
            '  '
          ]),
          ['https://a.apk', 'https://b.apk']);
    });

    test('version.json 的 urls 被解析，主 url 始终排第一', () {
      final info = VersionInfo.fromJson({
        'versionName': '1.2.6',
        'versionCode': 2021,
        'url': 'https://a.apk',
        'urls': ['https://b.apk', 'https://a.apk'],
        'size': 1,
      });
      expect(info.downloadUrls, ['https://a.apk', 'https://b.apk']);
    });

    test('只有 apkUrl 旧字段也能用', () {
      final info = VersionInfo.fromJson({
        'version': '1.0.1',
        'buildNumber': 2,
        'apkUrl': 'https://legacy.apk',
      });
      expect(info.downloadUrls, ['https://legacy.apk']);
      expect(info.url, 'https://legacy.apk');
    });

    test('完全没有地址 → 空列表（上层提示未配置）', () {
      final info = VersionInfo.fromJson({'versionCode': 1});
      expect(info.downloadUrls, isEmpty);
    });
  });

  group('下载响应类型识别（防止把错误页写成 APK）', () {
    test('HTML 错误页 → true', () {
      expect(looksLikeHtmlPage('text/html; charset=utf-8'), isTrue);
      expect(looksLikeHtmlPage('TEXT/HTML'), isTrue);
    });
    test('JSON 错误体 → true', () => expect(looksLikeHtmlPage('application/json'), isTrue));
    test('APK 正常类型 → false', () {
      expect(looksLikeHtmlPage('application/vnd.android.package-archive'), isFalse);
      expect(looksLikeHtmlPage(null), isFalse);
    });
  });

  group('partPlan 分片续传计划', () {
    test('从头下载：所有分片全量', () {
      expect(partPlan([10, 20, 5], 0), [
        (0, 0),
        (1, 0),
        (2, 0),
      ]);
    });

    test('断点落在第二片中间：该片从断点续，后续片全量', () {
      expect(partPlan([10, 20, 5], 15), [
        (1, 5),
        (2, 0),
      ]);
    });

    test('断点正好压在分片边界', () {
      expect(partPlan([10, 20, 5], 10), [
        (1, 0),
        (2, 0),
      ]);
      expect(partPlan([10, 20, 5], 30), [
        (2, 0),
      ]);
    });

    test('断点在最后一片末尾：无需再下', () {
      expect(partPlan([10, 20, 5], 35), isEmpty);
    });

    test('断点超出总长（脏分段）：返回空，由上层按损坏重下', () {
      expect(partPlan([10, 20, 5], 40), isEmpty);
    });
  });
}
