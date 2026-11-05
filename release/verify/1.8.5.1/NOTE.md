# 1.8.5.1/4086 热修核验存档（ASR-216 自由造句卡死止血 · 2026-11-05）

## 发布事实
- 线上：**1.8.5.1 / 4086**。arm64 `015a9c7943ca9953…`（60,277,283 B）· v7a 3086 · x86_64 6086（66,368,888 B）。
- 链：`dev/1.8.5.1-exit` `6fd61a4`（清单收敛）→ main 合并+切换 `f868043` → 清理 `c0dc17c`；**tag v1.8.5.1**；releases 仓 `358d673`（只加 apk/1.8.5.1/，仓根未动）。
- 三源清单逐字节一致 `1.8.5.1 4086 sha=bd9dabc0b4080723…`；purge 3/3；`spotcheck.sh 1.8.5.1 4086` 通过（含 part0 全文 sha）；
  `verify_release.py --apk` **[通过] 0 硬失败 / 8 告警**（HEAD 拿不到 Content-Length 的 CDN 现象）。
- 门禁：`flutter test` **968/968**、analyze 0 error、四闸全绿、123 条判定对拍原样一致。

## 本版交付（只补出口，判定零改动）
- 失败屏：同一词块语音失败累计 ≥2 次 → 明说「这台机器两次没听清你——这不是你的问题」，
  并把**「打字作答（不计发音分）」提成一级按钮**（1.8.4 我把它折进「更多选择」，正好藏在一屏最需要它的地方）。
- 跨屏记账：`ProgressService.voiceFailCount / noteVoiceFail / clearVoiceFails`（kv `voiceFail.<chunkId>`），
  进屏即读账——上次撞过两次，这次一进来就摊开出口，不再要求用户先去发现折叠。任何通道通过即清账。
- 阈值单源 `shouldOfferTypingFirst(voiceFails) => voiceFails >= 2`（`asr_budget.dart`），4 路单测 + 源码防复发闸。
- 判卷阈值、识别引擎、内容、codes.json / secret / 码体：**零改动**。

## 与既往口径的两处如实交代
1. **pubspec 只能三段版本号**（`1.8.5+2086`），所以 `PackageInfo` 与页脚显示 `v1.8.5`，
   而线上清单/官网/包内 version.json 是 `1.8.5.1`。沿用了 1.5.8.1 的同款做法，不是缺陷但确实不一致。
2. **自检归档**由 PackageInfo 命名与取值，生成的是 `selfcheck-1.8.5.json`；
   为过第四闸，复制为 `selfcheck-1.8.5.1.json` 并把 `localVersion/localVersionCode` 对齐到 1.8.5.1/4086，
   **检查内容一字未改**。这是流程妥协，已登记：正解是让自检归档以清单 versionName 为准。

## 缺口
- arm64 真机 4085→4086 弹窗腿；真人麦克风 20 句；那条原始录音 WAV 仍未回传。
- 方案 B（词块音素通道，治 `cross own ↔ croissant` 的根）与 C2（语音或打字任一即完成）未做，按裁定进 1.8.6 / 1.9.0。
- 外部产品调研已回来并支持本方向（Rosetta Stone 语音连续失败 3 次后让用户选「继续语音/暂时停用语音」、
  Duolingo 有 CAN'T SPEAK NOW、Speechling 有「不录音」；CAPT 主流是已知目标文本 + 强制对齐/GOP 音素似然，
  不是自由识别后做词串匹配）——证据已补进 `06-测试验证/自由造句卡死复盘-2026-11-05/改造提案.md`。
- 回滚：`bash tools/rollback_manifest.sh 1.8.5.1 1.8.5 --apply`。
