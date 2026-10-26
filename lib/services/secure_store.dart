import 'package:flutter/services.dart';

/// kv 里本机密文的统一前缀：`enc:v1:<base64(iv||ciphertext)>`。
/// 没有该前缀的旧值视为历史明文，由 ProgressService 在 init 时加密回写。
const String kEncPrefix = 'enc:v1:';

/// 本机密文能力：encrypt 返回可落库的完整令牌（含 [kEncPrefix]）。
abstract class KeyCipher {
  Future<String> encrypt(String plain);
  Future<String?> decrypt(String payload);
}

/// Android Keystore（AES-256-GCM）实现：密钥在系统密钥库内，明文只在内存。
class KeystoreCipher implements KeyCipher {
  static const MethodChannel _ch = MethodChannel('chunkspoke/secure_store');

  const KeystoreCipher();

  @override
  Future<String> encrypt(String plain) async {
    final out = await _ch.invokeMethod<String>('encrypt', {'value': plain});
    if (out == null || out.isEmpty) {
      throw StateError('keystore encrypt unavailable');
    }
    return '$kEncPrefix$out';
  }

  @override
  Future<String?> decrypt(String payload) async {
    if (!payload.startsWith(kEncPrefix)) return payload;
    try {
      return await _ch.invokeMethod<String>(
          'decrypt', {'value': payload.substring(kEncPrefix.length)});
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }
}
