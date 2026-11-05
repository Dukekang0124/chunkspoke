# ASR-214 · 真机「USE WAS GREAT」吞词取证与修复（2026-11-05）

## 一 现象（老板真机截图）

第 6/6 步「自由造句」，目标词块 `main course`，母语者参考句 `The main course was great.`
识别回：`你说：USE WAS GREAT（增强识别）` → 判「听到了，但没用上 main course」= 用户被误判失败。

## 二 三条真因（全部本机生产同款模型实测，非推断）

**① 增强识别被当成了主引擎（决定性）**
`speech.dart:recognizeOpen` 的 ASR-191「模式 B」是：用户开了增强包 → 开放式识别**先走 zipformer**，
Vosk 完全不参与。而 40 句生产口径实测（`head2head-40.json`，Zira 标准美音、前卷 2 s、无截断）：

| 引擎 | WER | 整句全对 | 空结果 | RTF |
|---|---|---|---|---|
| vosk-small-en-us-0.15 | **0.0492** | **82.5%** | 0 | 0.220 |
| zipformer-en-20M-int8 | 0.4317 | 40.0% | 10 | 0.037 |
| zipformer + 热词 | 0.1858 | 40.0% | 0 | 0.044 |

同一条目标句：Vosk 逐字全对 `the main course was great`；zipformer **零截断**就听成 `IN COURSE WAS GREAT`。

**② 「目标句当热词」从未生效**
`tokens.txt` 里没有 `MAIN`/`COURSE` 这类整词 token（只有 `▁MA`、`▁COURSE` 等子词），
encoder 每次都打 `Encode hotwords failed, skipping`。改成子词写法 `▁MA IN ▁COURSE` 仍被拒
（它把 `▁` 剥掉后找不到 `MA`）；连「荒谬热词 `▁BANANA ▁KANGAROO`」都不改变任何输出。
⇒ **ASR-209 记录的「热词使 WER 0.332→0.170」是 misattribution**：那一段增益来自
`greedy_search → modified_beam_search`（App 侧本来就一直是 beam search），不是热词。

**③ 句首丢 300–500 ms 也会误判（Vosk 同样中招）**
`asr214_onset_probe.py` 句首截断扫描（target=词块 `main course`）：

| 截断 | Vosk 自由 | 判定 | zipformer |
|---|---|---|---|
| 0–200 ms | the main course was great | 过 | IN COURSE WAS GREAT（不过） |
| 300 ms | in course was great | 不过 lowCore | **USE WAS GREAT** ← 与截图逐字相同 |
| 400 ms | course was great | 不过 lowCore | UZ WAS GREAT |
| 600 ms | source was great | 不过 | 'S GREAT |

预卷 `kPreRollMs = 400` 只覆盖**按下之后**的音频；用户在按下前已开口就救不回来，
此时尾部明明逐字对上，却因缺首词直接记失败 = 把采集侧丢词算到用户头上。

## 三 本版修复（1.8.5，代码已落地并过闸）

- **F1 引擎位次归位**：`asr_budget.dart:useEnhancedFirstPass` 单源判据 —— Vosk 有文本就用 Vosk，
  只有空结果才让增强兜底；`speech.dart:recognizeOpen` 按此改写。防复发静态闸：
  源码里 Vosk 调用必须排在 `EnhancedAsrService` 之前。
- **F3 句首被吞判「接近」**：`speech_judge.dart:onsetLossSuspected`（Python 镜像 `vosk_sim.py` 同步，
  123 条对拍仍逐字一致）。三条同时成立才算嫌疑：识别比参考句短、目标词未全命中、
  与参考句共享 ≥2 个连续尾部词。命中后走既有灰带：不改判、不扣分、提示整句重说。
- **F4 二过词表加宽**：`recognizeWithTargetGrammarRetry` 新增 `extraPhrases`，
  自由造句把本级其他句/块并进 grammar（旧实现只喂词块两词，实测产出 `main course course main`）。
  守门不放松：二过仍须 `guardAsr(checkChunkStack: true)` + 判定层同时通过才改判。
- **F5 预算补齐**：`withinBudget<T>()`（手写 Completer，绕开 `Future.timeout` 在 T 非空时的
  运行时泛型崩）把 grammar 二过与 M1 降级重识也纳入同一个 3 s 预算 —— ASR-213 只包了一过。
- **F2 诚实化**：changelog 与代码注释不再宣称「热词已生效」，明写实测口径。

判卷阈值、识别引擎选型结论、内容、codes.json / secret / 码体：零改动。

## 四 门禁

`flutter test` **966/966**（含新增 13 项 ASR-214 用例）；`flutter analyze` 0 error（1 条历史 info）；
`python tools/test_asr_bench.py` 24 项 OK、`judge_parity` 123 条与 Dart 侧同判。

## 五 缺口（不许当成验收完成）

1. **未出包未上线**：1.8.5 三 ABI 构建 + 四闸 + 清单/官网/purge/复验尚未执行。
2. **真机取证仍缺一条**：请老板在出问题的那台手机上「设置 → 诊断 → 分享最近一条录音」发回，
   就能直接判定这次到底是 ① 引擎位次（F1 已修）还是 ③ 句首吞字（F3 已缓解）——
   两条修法都已就位，但只有原始 WAV 能告诉我们当时录音里到底有没有 "the main"。
3. 增强包（zipformer 20M）本身要不要继续留在包里：实测它比默认引擎差 8 倍 WER，
   只快 6 倍 RTF。建议改判为「低端机降速兜底」而非「更准」，或直接换更强的端侧引擎（调研另行给结论）。

## 六 外部选型调研（GitHub，2026-11-05，只调研未装）

结论：**先不换引擎**。本版修的是「位次错配 + 采集丢头 + 判定算错人」，换引擎解决不了这三条。
若真机复测证明默认引擎在真人软起音上仍不够，按此顺序加料（都是一手来源核过的）：

1. **拾音侧（零体积成本，优先）**：Silero VAD（MIT，`silero_vad.onnx` 2.33 MB，1.29 MB 的 op15 版也有）
   配 `speech_pad_ms` 30→约 200 做**语音起点回卷**；现成 Flutter FFI 包 `vad` 0.0.8（MIT，含 Android）。
   仓库 https://github.com/snakers4/silero-vad 、https://pub.dev/packages/vad
2. **Vosk 端点参数（改一行，无新依赖）**：Android 绑定确有
   `setEndpointerMode(0..3)` 与 `setEndpointerDelays(t_start_max, t_end, t_max)`；
   本模型 `conf/model.conf` **没写 rule1** ⇒ 继承 Kaldi 默认「初始静音 5.0 s」。
   来源 https://github.com/alphacep/vosk-api/blob/master/android/lib/src/main/java/org/vosk/Recognizer.java
   、https://github.com/kaldi-asr/kaldi/blob/master/src/online2/online-endpoint.h
3. **真要换更强的端侧英文模型**：Moonshine（MIT，`tiny-streaming` ≈45 MB，Open ASR 8 集均值 WER 12.0%，
   Android 有官方 Maven AAR 但**无 Flutter 绑定**，需自接 JNI）
   https://github.com/moonshine-ai/moonshine ；或 `vosk-model-en-us-0.22-large`（128 MB，WER 7.82/8.20）。
   sherpa-onnx 已内置 Moonshine 解码 + VAD + hotwordsFile，一套 FFI 可同时拿三件
   https://github.com/k2-fsa/sherpa-onnx 。
4. **未证实项（不许当结论用）**：非母语口音上的 WER 对比、AGC 起录爬升吃首音节的一手官方文档、
   `real-time-voice-bucket` 仓库是否存在。
