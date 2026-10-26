import 'package:flutter_test/flutter_test.dart';
import 'package:chunkspoke_flutter/services/update/version_compare.dart';

void main() {
  group('isNewerVersion (数值比较，禁止字符串)', () {
    test('remote > local → true', () => expect(isNewerVersion(10, 2013), isTrue));
    test('remote == local → false', () => expect(isNewerVersion(2013, 2013), isFalse));
    test('remote < local → false', () => expect(isNewerVersion(2013, 10), isFalse));
  });

  group('abiSlotOf (split-per-abi 槽位 = 千位)', () {
    test('基数直发 2058 → 2', () => expect(abiSlotOf(2058), 2));
    test('v7a 3058 → 3', () => expect(abiSlotOf(3058), 3));
    test('arm64 4058 → 4', () => expect(abiSlotOf(4058), 4));
    test('x86_64 6058 → 6', () => expect(abiSlotOf(6058), 6));
    test('0 / 负数 → 0（不可判）', () {
      expect(abiSlotOf(0), 0);
      expect(abiSlotOf(-1), 0);
    });
  });

  group('isUpdateForThisDevice (只认同 ABI 槽位的更新，指令 MASTER §〇-1)', () {
    test('arm64 4057 → 清单 4058：同槽位且更高 → 弹',
        () => expect(isUpdateForThisDevice(4057, 4058), isTrue));
    test('arm64 已是最新 4058 → 4058：不弹',
        () => expect(isUpdateForThisDevice(4058, 4058), isFalse));
    test('arm64 本地更高（回滚态）→ 不弹',
        () => expect(isUpdateForThisDevice(4059, 4058), isFalse));
    // 这一条就是被修掉的缺陷：v7a 数值小，旧实现会弹一个装不上的 arm64 包
    test('v7a 3057 vs 清单 4058：跨槽位 → 不弹（旧实现误弹）',
        () => expect(isUpdateForThisDevice(3057, 4058), isFalse));
    test('x86_64 6057 vs 清单 4058：跨槽位 → 不弹（与既有限制一致）',
        () => expect(isUpdateForThisDevice(6057, 4058), isFalse));
    test('基数包 2057 vs 清单 4058：跨槽位 → 不弹',
        () => expect(isUpdateForThisDevice(2057, 4058), isFalse));
    test('同槽位内 v7a 3057 → 3058：弹（清单换成 v7a 主推荐时仍可用）',
        () => expect(isUpdateForThisDevice(3057, 3058), isTrue));
    test('清单缺 versionCode（0）→ 绝不弹',
        () => expect(isUpdateForThisDevice(4057, 0), isFalse));
    test('本机 versionCode 异常（0）→ 绝不弹',
        () => expect(isUpdateForThisDevice(0, 4058), isFalse));
  });

  group('parseVersionCode (容错)', () {
    test('int 透传', () => expect(parseVersionCode(2013), 2013));
    test('num 透传', () => expect(parseVersionCode(2013.0), 2013));
    test('字符串数字', () => expect(parseVersionCode('2013'), 2013));
    test('null → 0', () => expect(parseVersionCode(null), 0));
    test('空字符串 → 0', () => expect(parseVersionCode(''), 0));
    test('非数字 → 0', () => expect(parseVersionCode('abc'), 0));
  });
}
