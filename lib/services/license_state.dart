// 1.6.0（LIC-1）· 授权状态：唯一真源。
//
// UI 只读这里，不各自缓存；gate 只做 AND 收窄，不改任何既有推进语义。
//
// 存储（全部进 `kv` 表，不新增表、不改迁移版本）：
//   license.edition      归一后的档位 PRO / TRIAL / BETA（**不许存 PR0**）
//   license.nonce        5 字符 canonical
//   license.tag          10 字符 canonical
//   license.verifyState  ok / unverified / rejected
//   license.activatedAt  epoch ms，0 = 从未激活
//   license.tail         码后 4 位（纯展示）
//   license.secretFp     8 位 hex（只存指纹，永不存 secret）
//   license.deviceId     安装时生成一次的随机 ID（换绑用，不做硬件指纹）
import 'dart:math';

import 'package:flutter/foundation.dart';

import 'database.dart';
import 'license_code.dart';

/// 构建注入：`--dart-define=CS_UNLOCK_SECRET=...`（正式包必须给真 secret）。
const String kUnlockSecretEnv = String.fromEnvironment('CS_UNLOCK_SECRET');
const String kUnlockSecretPrevEnv =
    String.fromEnvironment('CS_UNLOCK_SECRET_PREV');

/// 仅在 debug 构建兜底用的测试 secret（与运营侧 `cs_codes.py --test` 同值）。
/// release 包未注入 define 时为空 → 只能校验结构、无法激活（宁可要真 secret）。
const String kBuiltinTestSecret = 'chunkspoke-test-secret-do-not-ship-0000';

const String kKvLicenseEdition = 'license.edition';
const String kKvLicenseNonce = 'license.nonce';
const String kKvLicenseTag = 'license.tag';
const String kKvLicenseVerifyState = 'license.verifyState';
const String kKvLicenseActivatedAt = 'license.activatedAt';
const String kKvLicenseTail = 'license.tail';
const String kKvLicenseSecretFp = 'license.secretFp';
const String kKvLicenseDeviceId = 'license.deviceId';

const String kVerifyOk = 'ok';
const String kVerifyUnverified = 'unverified';
const String kVerifyRejected = 'rejected';

/// 白名单三态（DDS §31.4）在本机的落点。
enum WhitelistLookup {
  /// 清单里查到且 status=active。
  active,

  /// 清单里查到但已吊销。
  revoked,

  /// 清单拉取成功但**没有这个 nonce**（未登记）。
  absent,

  /// 拉取失败 / 超时 / 解析失败 → 本地 HMAC 宽限。
  unavailable,
}

/// 功能级门（G-5/G-6/G-7 统一出口，禁止 UI 里散落 `if (isPro)`）。
enum LicenseFeature {
  /// 1.5.9 三项输出永久免费，显式列在这里，不许被 G–T 顺带锁掉。
  speechAssessment,
  studyCalendar,
  dictation,
  shareRecording,
  dataBackup,

  /// 1.6.0 新生：入口存在但标锁（非 PRO / 非老用户）。
  oralDiary,
}

class LicenseActivation {
  const LicenseActivation.ok(this.code, {required this.verifyState})
      : error = null,
        message = '';

  const LicenseActivation.fail(this.error, this.message)
      : code = null,
        verifyState = '';

  final LicenseCode? code;
  final String verifyState;
  final LicenseError? error;
  final String message;

  bool get ok => code != null;
}

class LicenseState extends ChangeNotifier {
  LicenseState({
    required AppDatabase db,
    required this.legacyEligible,
    List<String>? secrets,
    DateTime Function()? clock,
    Random? random,
  })  : _db = db,
        _clock = clock ?? DateTime.now,
        _random = random ?? Random.secure(),
        secrets = secrets ?? _secretsFromBuild();

  final AppDatabase _db;
  final DateTime Function() _clock;
  final Random _random;

  /// CURRENT 在前，PREV 兜底（双 secret 轮换期旧码继续可验）。
  final List<String> secrets;

  /// 老用户身份（1.5.10 判据结论）。legacy=1 → 全量放行，不需要码。
  final bool legacyEligible;

  String? _edition;
  String _nonce = '';
  String _tag = '';
  String _verifyState = kVerifyOk;
  int _activatedAt = 0;
  String _tail = '';
  String _secretFp = '';
  String _deviceId = '';
  bool _loaded = false;

  static List<String> _secretsFromBuild() {
    final out = <String>[];
    if (kUnlockSecretEnv.isNotEmpty) out.add(kUnlockSecretEnv);
    if (kUnlockSecretPrevEnv.isNotEmpty) out.add(kUnlockSecretPrevEnv);
    // 日常调试构建没有 define：用测试 secret 兜底，正式包必须显式注入。
    if (out.isEmpty && kDebugMode) out.add(kBuiltinTestSecret);
    return out;
  }

  bool get loaded => _loaded;

  /// 归一后的档位；从未激活为 null。
  String? get edition => _edition;

  String get nonce => _nonce;
  String get tag => _tag;
  String get verifyState => _verifyState;
  int get activatedAt => _activatedAt;
  String get tail => _tail;

  /// secret 指纹（8 位 hex）：只用于确认「这次是哪把钥匙验过的」。
  String get secretFp => _secretFp;

  String get deviceId => _deviceId;

  bool get hasLicense => _edition != null;

  /// 是否真的享有 PRO 权益：档位是 PRO 且没被吊销。
  /// TRIAL / BETA 在 1.6.0 **只解析不放行**（施工详单 §8-2）。
  bool get isPro => _edition == kEditionPro && _verifyState != kVerifyRejected;

  /// 全量权益 = PRO 或老用户。老用户终身全量，不受任何墙影响。
  bool get hasFullAccess => isPro || legacyEligible;

  /// G-1/G-2/G-3 的唯一判据：A–F 恒真；G 起要全量权益。
  bool allowsLevel(int index) => index < kFreeLevelCount || hasFullAccess;

  /// G-5/G-6/G-7 的统一出口。
  bool allows(LicenseFeature feature) {
    switch (feature) {
      case LicenseFeature.oralDiary:
        return hasFullAccess;
      case LicenseFeature.speechAssessment:
      case LicenseFeature.studyCalendar:
      case LicenseFeature.dictation:
      case LicenseFeature.shareRecording:
      case LicenseFeature.dataBackup:
        // 1.5.9 三项输出 + 1.5.10 备份：**永久免费**，写死在这里。
        return true;
    }
  }

  Future<void> load() async {
    _edition = _canonicalEdition(await _db.getKv(kKvLicenseEdition));
    _nonce = (await _db.getKv(kKvLicenseNonce)) ?? '';
    _tag = (await _db.getKv(kKvLicenseTag)) ?? '';
    _verifyState = (await _db.getKv(kKvLicenseVerifyState)) ?? kVerifyOk;
    _activatedAt = int.tryParse(await _db.getKv(kKvLicenseActivatedAt) ?? '') ?? 0;
    _tail = (await _db.getKv(kKvLicenseTail)) ?? '';
    _secretFp = (await _db.getKv(kKvLicenseSecretFp)) ?? '';
    _deviceId = (await _db.getKv(kKvLicenseDeviceId)) ?? '';
    if (_deviceId.isEmpty) {
      _deviceId = _newDeviceId();
      try {
        await _db.setKv(kKvLicenseDeviceId, _deviceId);
      } catch (_) {
        // 写失败不影响授权；下次启动再生成。
      }
    }
    _loaded = true;
    notifyListeners();
  }

  /// 存进 kv 的档位必须**先归一**：存 `PR0` → flag 查不到 → 付了钱还锁着（T-C）。
  static String? _canonicalEdition(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    final clean = canonLicenseAlnum(raw.trim().toUpperCase());
    // 档位段用等价类比对（PRO 含 O，不能做 O→0）
    return matchEdition(raw.trim().toUpperCase()) ??
        (kEditions.contains(clean) ? clean : null);
  }

  String _newDeviceId() {
    const hex = '0123456789abcdef';
    return List.generate(16, (_) => hex[_random.nextInt(16)]).join();
  }

  /// 输码激活。白名单三态在这里收口（DDS §31.4）：
  ///   active      → 落盘 ok
  ///   unavailable → 落盘 unverified（本地 HMAC 宽限，不锁）
  ///   revoked     → 拒绝（已吊销的码不能复活）
  ///   absent      → 拒绝（未登记新码；防「旧 secret 自造码」）
  Future<LicenseActivation> activate(
    String input, {
    required WhitelistLookup whitelist,
  }) async {
    final check = verifyLicenseCode(input, secrets);
    if (!check.ok) {
      return LicenseActivation.fail(
          check.error, licenseErrorMessage(check.error, check.detail));
    }
    final code = check.code!;
    if (whitelist == WhitelistLookup.revoked) {
      return const LicenseActivation.fail(
          LicenseError.tag, '这枚码已被停用，不再能激活。');
    }
    if (whitelist == WhitelistLookup.absent) {
      return const LicenseActivation.fail(
          LicenseError.tag, '这枚码不在发行清单里，请拿码尾号找发码人核对。');
    }
    final state = whitelist == WhitelistLookup.active
        ? kVerifyOk
        : kVerifyUnverified;
    await _persist(code, state, check.secretFp);
    return LicenseActivation.ok(code, verifyState: state);
  }

  /// 启动/联网后刷新白名单结论（不改档位，只改 verifyState）。
  Future<void> applyWhitelist(WhitelistLookup lookup) async {
    if (_edition == null) return;
    String next;
    switch (lookup) {
      case WhitelistLookup.active:
        next = kVerifyOk;
      case WhitelistLookup.revoked:
        next = kVerifyRejected; // 真吊销：锁
      case WhitelistLookup.absent:
        next = kVerifyUnverified; // 第 2 态：已激活但清单消失 → 宽限不锁
      case WhitelistLookup.unavailable:
        return; // 第 3 态：断网不改变本地状态
    }
    if (next == _verifyState) return;
    _verifyState = next;
    try {
      await _db.setKv(kKvLicenseVerifyState, next);
    } catch (_) {}
    notifyListeners();
  }

  Future<void> _persist(LicenseCode code, String state, String fp) async {
    _edition = code.edition;
    _nonce = code.nonce;
    _tag = code.tag;
    _tail = code.tail;
    _secretFp = fp;
    _verifyState = state;
    _activatedAt = _clock().millisecondsSinceEpoch;
    await _db.setKv(kKvLicenseEdition, code.edition);
    await _db.setKv(kKvLicenseNonce, code.nonce);
    await _db.setKv(kKvLicenseTag, code.tag);
    await _db.setKv(kKvLicenseTail, code.tail);
    await _db.setKv(kKvLicenseSecretFp, fp);
    await _db.setKv(kKvLicenseVerifyState, state);
    await _db.setKv(kKvLicenseActivatedAt, '$_activatedAt');
    notifyListeners();
  }
}
