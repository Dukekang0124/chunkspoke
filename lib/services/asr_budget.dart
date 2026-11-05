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

/// ASR-214 F1 · 一过用哪个引擎的**单源判据**。
///
/// 真机取证（`release/ASR-214/`）：第 6/6 步自由造句，目标词块 `main course`，
/// 参考句 "The main course was great."，用户被回 `USE WAS GREAT（增强识别）`。
/// 本机生产同款模型复现：
///  · Vosk small-en-us-0.15 自由解码在理想音频上逐字全对；
///  · zipformer-en-20M-int8 **零截断**就把 "the main" 听成 "in"，
///    截 300 ms 精确复现 `USE WAS GREAT`；
///  · 40 句生产口径实测（前卷 2 s，无截断）：Vosk WER 0.049 / 整句全对 82.5%，
///    zipformer WER 0.432 / 整句全对 40.0%、空结果 10/40。
/// 而 ASR-191「模式 B」把增强做成了**主引擎**（用户一开就顶掉 Vosk），
/// 与「并列」拍板不符，直接造成「用户说对了却被判错」。
///
/// 判据固定为：**Vosk 有文本就用 Vosk；只有它空结果时才让增强兜底**。
/// 两引擎取优仍归判定层（grammar 二过 + retryOpenWithFallback），不在这里做。
bool useEnhancedFirstPass({
  required bool voskHasText,
  required bool enhancedHasText,
}) =>
    !voskHasText && enhancedHasText;

/// ASR-214 F5 · 二过与降级的预算包装（返回可空）。
///
/// ASR-213 P0-1 只包了**一过** `recognizeOpen`；grammar 二过与 M1 降级重识
/// 仍是裸 await——它们同样能拖到十几秒，用户卡在「识别中…」一样是 P0。
/// 现在三段都在同一个 [kAsrBudget] 下，超预算按「没有结果」收口，
/// 判定层自然走「没听到声音」分支，不改判、不扣分。
/// ASR-216 · 「同一块说了几次仍没被听清」之后该怎么办的单源判据。
///
/// 真机实况：`a croissant` 被识别成 `i a the cross own`（借词被切成 cross+own），
/// 增强引擎直接吐 `NG`；判定要求词块整词出现 → 用户说对了也判不过，
/// 而 1.8.4 我把「改转写/打字作答」折进了「更多选择」，等于把逃生口藏起来。
/// 外部先例（已核到官方文档）：Rosetta Stone 语音连续失败 3 次后让用户在
/// 「继续用语音 / 暂时停用语音」之间选；Duolingo 口语题有 CAN'T SPEAK NOW；
/// Speechling 有「不录音」直接看答案。开口不该是硬闸门。
bool shouldOfferTypingFirst(int voiceFails) => voiceFails >= 2;

Future<T?> withinBudget<T>(Future<T?> Function() run,
    {Duration budget = kAsrBudget}) {
  // 不用 Future.timeout：它的 onTimeout 泛型在 T 非空时会推成 T（不是 T?），
  // 单测里 `withinBudget<String>` 直接运行时类型崩——手写 Completer 才可控。
  final done = Completer<T?>();
  final timer = Timer(budget, () {
    if (!done.isCompleted) done.complete(null);
  });
  run().then((value) {
    timer.cancel();
    if (!done.isCompleted) done.complete(value);
  }).catchError((Object _) {
    // 二过/降级自己炸了不该拖垮判定：按「没有结果」收口，一过结论原样保留。
    timer.cancel();
    if (!done.isCompleted) done.complete(null);
  });
  return done.future;
}
