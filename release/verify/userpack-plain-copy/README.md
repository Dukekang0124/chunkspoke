# 「我的英语本 · 粘贴任意文本」文案与交互优化 — 自测证据清单

日期：2026-11-10（本机时间，截图时间戳 08:57–09:13）
分支：`dev/1.9.0-userpack`（**未 commit / 未 bump / 未合 main**）
构建：debug x64（`build/app/outputs/flutter-apk/app-debug.apk`），versionCode 2091，`adb install -r -d`
设备：模拟器 `emulator-5554`（AVD cs_test，720×1600），包名 `com.chunkspoke.app`
输入法：ADB Keyboard（`input text` 注入英文粘贴文本）

## 一、本轮改了什么（展示层为主）

- 入口与全链路命名统一为「我的英语本」，去「模块/导入/语块/解析」等技术词。
- 新增「粘贴任意文本」：短文/对话/句子直接粘贴 → 自动整理成句子（`lib/services/user_text_parser.dart`，只按结构切分，**不翻译、不猜词义**）。
- 添加页重写：粘贴即识别、预览说人话（「这一页只是看看，不会保存」）、生成后「保存并开始学」直达六步学习。
- 预览页支持带入已粘贴文本（`UserPreviewScreen(initialText:)`），免费可看。
- 付费墙文案改日常表达：「保存到我的英语本需要解锁码」+ 退出按钮「先继续学免费内容」。
- 存储键与 `user:` 命名空间不变；官方计数/复习排期不受影响；整理/预览/读取/删除永久免费，仅「保存」需解锁码。

## 二、门禁结果（本机实跑）

| 项 | 结果 |
|---|---|
| `flutter analyze` | No issues found!（2.2s） |
| `flutter test`（全量） | **1084 All tests passed!** |
| `tools/preflight_invariants.sh` | **FAIL=1 WARN=0**；唯一 FAIL 原文：「FAIL main 已含 user_package.dart（D 轮被合入，违反红线 3）」——结构性事实（该功能已随 1.9.0/1.9.1 正式上线），非本轮引入 |
| preflight 其余项 | sha 匹配 5f9fe01e45f55668…；沙盒 raw 直链 200；工作树 ≤1 GB（1004 MB）；清单自洽 main 底版 9f545ff4 |

## 三、付费腿演练口径（重要，勿当卖码证据）

- 演练码：`CSPROFXSYFR3YT0PTZ5D`（运营自测 `cs_codes.py --test` 产物，secretFp **88f56da5**，origin=BUILTIN-TEST，**禁止发人、禁止进 codes.json**）。
- 激活方式：debug 包内置测试 secret（`kBuiltinTestSecret`，kDebugMode 回落）+ **飞行模式**使白名单不可达 → 本地 HMAC 宽限（verifyState=unverified，非 rejected）。
- **未上传任何码、未动 codes.json / secret / version.json / 发布链脚本**。本证据只证明「激活→保存→进学习」链路可用，不构成售卖/线上白名单验收。

## 四、截图（14 张）

| 文件 | 证明什么 |
|---|---|
| 01_home_entry.png | 首页入口命名「我的英语本」，无技术词 |
| 02_add_first.png | 添加页首屏：粘贴框 + 日常化引导 |
| 03_pasted_text.png | 直接粘贴 7 句咖啡馆对话原文 |
| 04_parsed_top.png | 整理结果顶部：「整理好了 · 一段英文」 |
| 05_parsed_actions.png | 「可以了：7 句」+ 预览/保存动作 |
| 06_preview_prefilled.png | 预览页自动带入已粘贴文本（不用重贴） |
| 07_preview_sentences.png | 预览逐句 + 「这一页只是看看，不会保存 —— 不动你的学习记录，也不影响官方内容。」 |
| 08_save_wall.png | 付费墙新文案 + 「先继续学免费内容」退出按钮 |
| 09_activation_grace.png | 演练码激活成功（绿字「已激活（暂时没连上清单，先按本地校验放行）。」，20/20 位校验） |
| 10_saved_into_learning.png | 保存后直达学习：学习·我的英语本 第 1/6 步·锚定 第 1/7 块 Good morning! |
| 11_home_with_book.png | 首页台账出现「我的英语本 / 7 句 · 11月10日存的 · 和官方内容分开记」；官方卡计数不变（已掌握 0 / 新学 6） |
| 12_book_detail.png | 本详情：共 7 句 / 存于 2026-11-10 01:10 / 同一套练习 + 1/3/7/14 复习 / 官方进度不变 / 开始学 / 复习这本（未到期置灰） |
| 13_reentry_learning.png | 从首页台账重进学习：第 1/6 步·锚定，第 1/7 块 |
| 14_step2_disassemble.png | 六步推进到第 2/6 步·拆解（Good / morning! 卡片） |

## 五、录屏（3 段）

| 文件 | 覆盖 | 备注 |
|---|---|---|
| walk_free_path.mp4（4,130,381 B） | 免费腿：首页 → 添加 → 粘贴 → 整理 → 预览 | 全程无付费动作 |
| walk_paid_leg.mp4（4,206,473 B） | 付费腿：首页 → 粘贴 → 整理 → 墙 → 我已有码 → 飞行模式 → 激活 | 170s 上限截断于激活后，保存→进学习一刻由截图 10 + 下段补证 |
| walk_reentry_learning.mp4（1,163,465 B） | 重进腿：首页台账 → 本详情 → 学习第 1 步 → 第 2 步 | 证明持久化 + 六步闭环可续 |

## 六、设备终态与边界

- 模拟器：飞行模式已关闭（网络恢复）；本地已激活 PRO（演练码，unverified 宽限）；已存「我的英语本」7 句。**仅本机，未上传。**
- 未 commit、未 bump、未合 main、未动 version.json / codes.json / secret / 发布链两脚本 / 承重墙目录。
- 真机腿（arm64 弹窗 + 真人走查）不可代劳，仍欠；本轮证据全部来自模拟器。