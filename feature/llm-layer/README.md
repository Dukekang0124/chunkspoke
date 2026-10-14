# feature/llm-layer — ChunkSpoke LLM 层存档（v1.1 候选 · 未验收）

> 隔离方式：项目未启用 git，故以目录代替 `feature/llm-layer` 分支存档。
> 目的：越界代码不删、可恢复，但**不进任何构建分支**。

## 为何被摘除（2026-10-13，R2 指令）
- 违反 v2.0 第十节第 7 条红线：**禁止越界实现——不做 AI 对话、不做自然度判定**。
- 违反「versionCode=2 仅版本号变更，零功能改动」指令。
- `judgeSay()` = 语义/自然度判定；`hint()` = AI 提示 —— 二者均属 Roadmap **v3**，未经验收不得进构建。
- 四个 API Key **硬编码进源码**（APK 可反编译提取 = 公开配额），为一票否决项。

## 存档内容
- `llm.dart`：完整 LLM 服务（4 模型优先降级链 + judgeSay + hint）。
- 接入点（已摘除，记录在此便于恢复）：
  - `lib/steps/say_widget.dart`：移除 `LlmService _llm` 字段、`judgeSay` 调用、`hint` 调用与 `_aiHint()`。
  - `lib/screens/settings.dart`：移除 AI 增强开关、模型链展示、Test 按钮。
  - `lib/services/speech.dart`：`SayOutcome.aiNote` 字段已移除。
  - `lib/services/loaders.dart`：`ProgressService.aiEnabled/setAiEnabled` 已移除。

## 恢复前置条件（v1.1 评审通过后方可执行）
1. **密钥政策**：四个 Key 不得硬编码。新增设置页 provider 配置 UI，Key 由用户填入
   （与 Azure Key 一致，存于 Hive，不入源码、不打包）。
2. **判据纪律**：`judgeSay` 仅作**附加信息展示**，永不作为通过/失败判据，
   不得破坏既有 L1/L2/L3 降级链。
3. **静默降级**：必须定义全部 provider 失败时回到 Text Match / L3 的降级行为，
   且任一网络异常不得阻断 Say 步主流程。
4. **有效性核验**：四个模型 ID 与 Key 的真实归属、配额、可用性须逐个验证
   （尤其 `agnes-2.5-flash` 的真实性与配额来源）。
5. 恢复后单独发版（versionCode 递增），不复用 versionCode=2 测试夹具。
