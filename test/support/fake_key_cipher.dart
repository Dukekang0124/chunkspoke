import 'dart:convert';

import 'package:chunkspoke_flutter/services/secure_store.dart';

/// 单测用本机密文替身：与 KeystoreCipher 同约定（enc:v1: + Base64），
/// 但不需要平台通道，可在 Windows 上跑。
class FakeKeyCipher implements KeyCipher {
  bool failDecrypt = false;
  int encryptCount = 0;

  @override
  Future<String> encrypt(String plain) async {
    encryptCount++;
    return '$kEncPrefix${base64Url.encode(utf8.encode(plain))}';
  }

  @override
  Future<String?> decrypt(String payload) async {
    if (!payload.startsWith(kEncPrefix)) return payload;
    if (failDecrypt) return null;
    return utf8.decode(base64Url.decode(payload.substring(kEncPrefix.length)));
  }
}
