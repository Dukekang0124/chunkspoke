// 1.6.0（LIC-1）· 白名单拉取 + 三态判定 + 吊销处置。
//
// 纪律（DDS §31.4 / 施工详单 §1 M-3）：
//   · 网络失败**必须走本地宽限**，断网 ≠ 未登记；
//   · codes.json **只增不删**，吊销靠 status 字段；
//   · 拉取失败绝不阻塞启动，也绝不把用户锁在门外。
import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'license_state.dart';

/// 线上清单：jsDelivr 主源 → raw 回退（与下载管线同一套换源思路）。
const String kCodesJsonJsDelivr =
    'https://cdn.jsdelivr.net/gh/Dukekang0124/chunkspoke-releases@main/codes.json';
const String kCodesJsonRaw =
    'https://raw.githubusercontent.com/Dukekang0124/chunkspoke-releases/main/codes.json';

const List<String> kCodesJsonSources = [kCodesJsonJsDelivr, kCodesJsonRaw];
const Duration kWhitelistTimeout = Duration(seconds: 15);

class WhitelistSnapshot {
  WhitelistSnapshot({required this.statusByNonce, required this.source});

  /// nonce → status（active / revoked）
  final Map<String, String> statusByNonce;
  final String source;

  int get size => statusByNonce.length;

  WhitelistLookup lookup(String nonce) {
    if (nonce.isEmpty) return WhitelistLookup.absent;
    final status = statusByNonce[nonce];
    if (status == null) return WhitelistLookup.absent;
    return status == 'revoked' ? WhitelistLookup.revoked : WhitelistLookup.active;
  }
}

/// 解析清单文本；坏文本返回 null（绝不猜、不降级）。
WhitelistSnapshot? parseCodesJson(String body, {String source = ''}) {
  try {
    final raw = jsonDecode(body);
    if (raw is! Map) return null;
    final list = raw['codes'];
    if (list is! List) return null;
    final map = <String, String>{};
    for (final item in list) {
      if (item is! Map) continue;
      final nonce = item['nonce']?.toString() ?? '';
      if (nonce.isEmpty) continue;
      map[nonce] = item['status']?.toString() ?? 'active';
    }
    return WhitelistSnapshot(statusByNonce: map, source: source);
  } catch (_) {
    return null;
  }
}

class LicenseGate {
  LicenseGate({
    http.Client? client,
    this.timeout = kWhitelistTimeout,
    List<String>? sources,
  })  : _client = client ?? http.Client(),
        sources = sources ?? kCodesJsonSources;

  final http.Client _client;
  final Duration timeout;
  final List<String> sources;

  /// 拉取失败返回 null（调用方按 unavailable 处理，**不锁**）。
  Future<WhitelistSnapshot?> fetch() async {
    for (final url in sources) {
      try {
        final res = await _client.get(Uri.parse(url)).timeout(timeout);
        if (res.statusCode != 200) continue;
        final snap = parseCodesJson(utf8.decode(res.bodyBytes), source: url);
        if (snap != null) return snap;
      } catch (_) {
        // 换下一个源；全失败 → null
      }
    }
    return null;
  }

  /// 单码查询：拉不到清单一律 unavailable（本地 HMAC 宽限）。
  Future<WhitelistLookup> lookup(String nonce) async {
    final snap = await fetch();
    if (snap == null) return WhitelistLookup.unavailable;
    return snap.lookup(nonce);
  }

  /// 启动/联网后刷新三态结论；失败保持本地不动。
  Future<void> refresh(LicenseState state) async {
    if (!state.hasLicense) return;
    final snap = await fetch();
    if (snap == null) {
      await state.applyWhitelist(WhitelistLookup.unavailable);
      return;
    }
    await state.applyWhitelist(snap.lookup(state.nonce));
  }
}
