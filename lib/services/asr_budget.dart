import 'dart:async';

import 'vosk_engine.dart';

/// ASR-213（1.8.4 热修波）· 开口练习的时间预算单源。
///
/// 新用户实测（1.8.3 / 4083）抓到一条 P0：静音录音停止后，从「识别中…」到出
/// 判定实测 **10–16 秒**，期间没有超时、没有进度、没有可点的取消——新人第一
/// 次跟读最容易撞上（不敢出声 / 麦克风被占用），极易判定 App 卡死并杀进程。
///
/// 两条预算，全部从这里取值，别在各步骤里各写一份：
///  · [kAsrBudget] 解码预算：超了就按「空转写」收口，交给判定层走「没听清」分支。
///  · [kRecordCap] 录音硬上限：到点自动收口去判定，防「忘了点停止」。
const Duration kAsrBudget = Duration(seconds: 3);
const Duration kRecordCap = Duration(seconds: 12);

/// 在 [budget] 内等一次识别；超时返回空转写（不是抛错、不是继续等）。
///
/// 注意：这只收口 **UI 的等待**。底层解码可能仍在跑，但其结果不再被消费——
/// 调用方拿到空文本后照常走守门器与判定层，行为与「真的没说话」完全一致。
Future<VoskResult> recognizeWithinBudget(
  Future<VoskResult> Function() run, {
  Duration budget = kAsrBudget,
}) =>
    run().timeout(budget, onTimeout: () => const VoskResult('', null));

/// ASR-213 P1-1 · 首启「本次更新」清单该不该弹。
///
/// 实测缺陷：全新安装的用户第一次点「开始学习」，弹的是写给老用户的修复日志
/// （"上次反馈的那句 main course"），对新人是纯噪音，还挡在第一次练习前面。
///
/// 判据用两个既有事实，不新增埋点：
///  · [seenForVersion] 非空 → 本机已经记录过版本，按「同版本不再弹、换版本才弹」走。
///  · [seenForVersion] 为空但 [legacyOneShot] 为真 → 老用户从 ≤1.8.3 升上来
///    （旧版一次性标记 `seenChangelog140` 已置位），该看这次更新说明。
///  · 两者皆空 → **全新安装**，不弹，只把版本号记下来，下次升级再弹。
bool shouldShowChangelog({
  required String? seenForVersion,
  required bool legacyOneShot,
  required String currentVersion,
}) {
  if (seenForVersion == currentVersion) return false;
  if (seenForVersion != null) return true;
  return legacyOneShot;
}
