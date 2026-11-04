// 1.6.0（LIC-1）· 解锁码：解析 / 归一化 / HMAC 校验。
//
// 纯 Dart，**零 Flutter 依赖**（不 import flutter/*）：这样 `dart test` 直接可跑，
// 也能和运营侧 `运营/unlock-ops/cs_codes.py` 对同一把 secret 对拍出同一枚码。
//
// 码规格（与 cs_codes.py 逐字符同源）：
//   20 字符 = CS + 档位(3) + nonce(5) + tag(10)
//   字表    = 标准 Crockford Base32: 0123456789ABCDEFGHJKMNPQRSTVWXYZ（无 I/L/O/U）
//   tag     = Crockford(HMAC-SHA256(secret, "EDITION|NONCE")) 取前 10 字符（50 bit）
//
// 归一化**必须分段**（曾据此出过真 bug）：
//   · 档位段做等价类比对（0↔O、1↔I↔L），**不做 O→0 替换**（否则 PRO 变 PR0）；
//   · nonce/tag 段才做 O→0、I→1、L→1。
import 'dart:convert';

import 'package:crypto/crypto.dart';

/// 标准 Crockford Base32（32 符号，无 I/L/O/U）。
const String kCrockfordAlphabet = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';

const String kLicensePrefix = 'CS';
const int kLicenseCodeLength = 20;

/// 字表里没有、但用户手输常敲出来的易混字符：收下后按分段规则归一。
const String kConfusableChars = 'ILO';

const String kEditionPro = 'PRO';
const String kEditionTrial = 'TRIAL';
const String kEditionBeta = 'BETA';
const List<String> kEditions = [kEditionPro, kEditionTrial, kEditionBeta];

/// 免费区 = 生存 S0 + A–F 共 7 关（index < 7，167 块）；G 起需 PRO 或老用户身份。
///
/// ASR-208 §一.4：L0 生存模块全免，免费口径 137 → 167。
const int kFreeLevelCount = 7;

enum LicenseError { length, charSet, prefix, edition, tag }

/// 解析成功的码（不含 secret 校验结论）。
class LicenseCode {
  const LicenseCode({
    required this.edition,
    required this.nonce,
    required this.tag,
  });

  /// 归一后的档位（PRO / TRIAL / BETA）。
  final String edition;
  final String nonce;
  final String tag;

  String get canonical => '$kLicensePrefix$edition$nonce$tag';

  /// 纯展示用：码后 4 位。
  String get tail => canonical.substring(canonical.length - 4);
}

/// 校验结论：成功带 [code] + 命中的 secret 指纹；失败带 [error] + 可读细节。
class LicenseCheck {
  const LicenseCheck.ok(this.code, {required this.secretFp})
      : error = null,
        detail = '';

  const LicenseCheck.fail(this.error, {this.detail = ''})
      : code = null,
        secretFp = '';

  final LicenseError? error;
  final String detail;
  final LicenseCode? code;
  final String secretFp;

  bool get ok => code != null;
}

/// 去空格/横线/全角空白 → 转大写。**不动字符本身**（与 Python `clean()` 同源）。
String cleanLicenseCode(String raw) {
  var s = raw.trim().toUpperCase();
  for (final ch in const [' ', '-', '\t', '\u3000', '\u2013', '\u2014']) {
    s = s.replaceAll(ch, '');
  }
  return s;
}

/// nonce / tag 段归一化：O→0、I→1、L→1。
String canonLicenseAlnum(String s) =>
    s.replaceAll('O', '0').replaceAll('I', '1').replaceAll('L', '1');

const Map<String, String> _editionEq = {
  '0': 'O',
  'O': 'O',
  '1': 'I',
  'I': 'I',
  'L': 'I',
};

String _editionKey(String s) =>
    s.split('').map((ch) => _editionEq[ch] ?? ch).join();

/// 档位段容错匹配：PRO / TRIAL / BETA 各自的等价类。
String? matchEdition(String seg) {
  final key = _editionKey(seg);
  for (final ed in kEditions) {
    if (_editionKey(ed) == key) return ed;
  }
  return null;
}

/// Crockford Base32 编码（MSB 优先，末组右侧补 0 位；与 Python `_crockford` 逐位一致）。
String crockfordEncode(List<int> data) {
  final bits = StringBuffer();
  for (final b in data) {
    bits.write(b.toRadixString(2).padLeft(8, '0'));
  }
  final s = bits.toString();
  final out = StringBuffer();
  for (var i = 0; i < s.length; i += 5) {
    final end = i + 5 > s.length ? s.length : i + 5;
    var chunk = s.substring(i, end);
    if (chunk.length < 5) chunk = chunk.padRight(5, '0');
    out.write(kCrockfordAlphabet[int.parse(chunk, radix: 2)]);
  }
  return out.toString();
}

/// tag = Crockford(HMAC-SHA256(secret, "EDITION|NONCE")) 前 10 字符。
String licenseTagFor(String secret, String edition, String nonce) {
  final mac = Hmac(sha256, utf8.encode(secret))
      .convert(utf8.encode('$edition|$nonce'));
  return crockfordEncode(mac.bytes).substring(0, 10);
}

/// secret 指纹：sha256 前 8 位 hex。**只暴露指纹，永不回显 secret。**
String licenseSecretFp(String secret) =>
    sha256.convert(utf8.encode(secret)).toString().substring(0, 8);

/// 常量时间比较：长度不同也把较短串补 0 走完全程，不短路。
bool timingSafeEquals(String a, String b) {
  final x = utf8.encode(a);
  final y = utf8.encode(b);
  var diff = x.length ^ y.length;
  final n = x.length > y.length ? x.length : y.length;
  for (var i = 0; i < n; i++) {
    final xi = i < x.length ? x[i] : 0;
    final yi = i < y.length ? y[i] : 0;
    diff |= xi ^ yi;
  }
  return diff == 0;
}

/// 只做结构解析（长度 / 字表 / 前缀 / 档位），不碰 secret。
LicenseCheck parseLicenseCode(String raw) {
  final c = cleanLicenseCode(raw);
  if (c.length != kLicenseCodeLength) {
    return LicenseCheck.fail(LicenseError.length, detail: '${c.length}');
  }
  final bad = <String>{};
  for (final ch in c.split('')) {
    if (!kCrockfordAlphabet.contains(ch) && !kConfusableChars.contains(ch)) {
      bad.add(ch);
    }
  }
  if (bad.isNotEmpty) {
    return LicenseCheck.fail(LicenseError.charSet, detail: bad.join());
  }
  if (!c.startsWith(kLicensePrefix)) {
    return LicenseCheck.fail(LicenseError.prefix, detail: c.substring(0, 2));
  }
  final edition = matchEdition(c.substring(2, 5));
  if (edition == null) {
    return LicenseCheck.fail(LicenseError.edition, detail: c.substring(2, 5));
  }
  final nonce = canonLicenseAlnum(c.substring(5, 10));
  final tag = canonLicenseAlnum(c.substring(10, 20));
  if (nonce.split('').any((ch) => !kCrockfordAlphabet.contains(ch)) ||
      tag.split('').any((ch) => !kCrockfordAlphabet.contains(ch))) {
    return const LicenseCheck.fail(LicenseError.charSet, detail: 'nonce/tag');
  }
  return LicenseCheck.ok(LicenseCode(edition: edition, nonce: nonce, tag: tag),
      secretFp: '');
}

/// 完整校验：结构 + 双 secret 的 HMAC tag（CURRENT 在前，PREV 兜底）。
LicenseCheck verifyLicenseCode(String raw, List<String> secrets) {
  final parsed = parseLicenseCode(raw);
  if (!parsed.ok) return parsed;
  final code = parsed.code!;
  final tried = <String>[];
  for (final secret in secrets) {
    if (secret.isEmpty) continue;
    tried.add(licenseSecretFp(secret));
    final expected = licenseTagFor(secret, code.edition, code.nonce);
    if (timingSafeEquals(expected, code.tag)) {
      return LicenseCheck.ok(code, secretFp: licenseSecretFp(secret));
    }
  }
  return LicenseCheck.fail(LicenseError.tag,
      detail: tried.isEmpty ? 'no-secret' : tried.join(','));
}

/// UI 错误分类文案（页内不自建判断，统一从这里取）。
String licenseErrorMessage(LicenseError? e, [String detail = '']) {
  switch (e) {
    case LicenseError.length:
      return '长度不对：解锁码是 20 个字符（现在是 ${detail.isEmpty ? '?' : detail} 个）。';
    case LicenseError.charSet:
      return '有不能识别的字符${detail.isEmpty ? '' : '：$detail'}。解锁码只用数字和字母。';
    case LicenseError.prefix:
      return '开头不是 CS${detail.isEmpty ? '' : '（读到 $detail）'}，可能粘错了一段。';
    case LicenseError.edition:
      return '档位「${detail.isEmpty ? '?' : detail}」不认识，请核对整枚码。';
    case LicenseError.tag:
      return detail == 'no-secret'
          ? '这个安装包没有内置校验钥匙，无法校验；请用正式安装包。'
          : '这枚码校验不通过：请逐段核对，注意 0/O、1/I/L 容易看混。';
    case null:
      return '';
  }
}
