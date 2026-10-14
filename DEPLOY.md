# ChunkSpoke 部署说明（v1.0.1 / buildNumber 2 · R2 纯净版）

本文件说明如何把本地构建产物发布到 GitHub Releases，并回填 `version.json`
与 `update_service.dart`，使 App 内「应用内更新」链路（方案 §9）真正可用。

> **R2 状态（2026-10-13）**：versionCode=2 包已**摘除越界 LLM 层**，恢复为纯版本号
> 垫片——仅 `pubspec` 版本号 `1.0.0+1 → 1.0.1+2`，功能与 v1.0.0 基线完全一致
> （L1/L2/L3 三层降级，零新增功能）。越界代码存档于 `feature/llm-layer/`（未验收）。

---

## 一、构建产物（R2 纯净版，重建后由 certutil 复核）

| ABI        | 文件                              | 大小 | SHA-256 (certutil)     |
|------------|-----------------------------------|------|------------------------|
| arm64-v8a  | app-arm64-v8a-release.apk         | 17,974,455 (17.1MB) | `28f2d11ded15bb67fadbcc8bf77f88c2bfdfbed6b7bbfd8b7923643990a6d60c` |
| armeabi-v7a| app-armeabi-v7a-release.apk       | 15,366,781 (14.6MB) | （按需 certutil 复核） |
| x86_64     | app-x86_64-release.apk            | 19,458,230 (18.5MB) | （按需 certutil 复核） |

> **Built**：2026/10/13 12:57:37（R2 纯净版 + 正式 launcher 图标，已摘除 LLM 层；原越界包 `609b351b…` 已作废，不得用于验收）。

> 仅交付 **arm64-v8a** 即可覆盖 99% 现代真机（验收用机型走此包）。
> 旧 49.12MB fat 包已从 `build/` 清理，仅保留 split-per-abi 三个产物。
> 原 `609b351b…`（arm64 18.12MB）为**含越界 LLM 层的废弃包**，不得用于验收，已作废。

---

## 二、version.json 字段含义（与 `lib/services/update_service.dart` 对齐）

`assets/version.json` 当前内容（R2 已去掉「AI 智能增强」措辞）：

```json
{
  "version": "1.0.1",
  "buildNumber": 2,
  "apkUrl": "",
  "contentUrl": "",
  "notes": "版本 v1.0.1：更新链路测试垫片（零功能改动）。"
}
```

| 字段         | 类型   | 含义                                                         |
|--------------|--------|--------------------------------------------------------------|
| `version`    | string | 展示版本号（来自 `pubspec.yaml` 的 `1.0.1+2` 主版本部分）    |
| `buildNumber`| int    | 构建号（来自 `+2`），App 仅当 `远端 > 本地` 才提示更新      |
| `apkUrl`     | string | **远端 APK 直链**（GitHub Releases 下载地址），更新时下载它  |
| `contentUrl` | string | 可选的更新说明页/增量内容地址，留空则只用 `notes`           |
| `notes`      | string | 更新日志，展示在更新弹窗                                     |

---

## 三、发布步骤（GitHub Releases）

1. 在仓库 `Releases` → `Draft a new release`。
2. Tag 填 `v1.0.1`，标题 `ChunkSpoke v1.0.1`。
3. 把 `app-arm64-v8a-release.apk` 拖入附件上传。
4. 发布（Publish release）。
5. 进入该 Release 页面，右键 `app-arm64-v8a-release.apk` → 复制链接地址，
   形如：
   `https://github.com/<owner>/<repo>/releases/download/v1.0.1/app-arm64-v8a-release.apk`

---

## 四、回填（两处必须改，否则更新链路拉不到包）

1. **`assets/version.json`** —— 把复制到的地址填入 `apkUrl`：
   ```json
   { "version": "1.0.1", "buildNumber": 2,
     "apkUrl": "https://github.com/<owner>/<repo>/releases/download/v1.0.1/app-arm64-v8a-release.apk",
     "contentUrl": "",
     "notes": "版本 v1.0.1：更新链路测试垫片（零功能改动）。" }
   ```
2. **`lib/services/update_service.dart`** 第 31 行 `remoteUrl`：
   ```dart
   static const String remoteUrl =
       'https://raw.githubusercontent.com/<owner>/<repo>/main/assets/version.json';
   ```
   > 注意：GitHub Releases 里的 `version.json` 不会自动暴露为 raw，
   > 请把 `assets/version.json` 也提交进仓库 main 分支（已默认在仓库中），
   > 用 `raw.githubusercontent.com` 直链作为 `remoteUrl`。

改完 `version.json` 需重新 `flutter build apk --release --split-per-abi`
（资源变更要重新打包），再按本文件「一」重新核 SHA-256。

---

## 五、真机验证更新链路（方案 §9）

1. 旧版（buildNumber 1）装机 → 设置页「检查更新」。
2. 服务端返回 buildNumber 2 > 1 → 弹出更新，显示真实下载进度。
3. 下载完成 → 引导「允许安装未知应用」→ 调起安装。
4. 安装后版本号应为 1.0.1 (2)；核心 L1/L2/L3 学习流程不变，无 AI 层介入。

---

## 六、LLM 层状态（已按 R2 摘除 · v1.1 候选 · 未验收）

`lib/services/llm.dart` 及其在 Say 步的全部接入（`judgeSay` / `hint` / `_aiHint` /
AI 开关 / 模型链 UI）已于 2026-10-13 从构建分支移除。原因：

- 违反 v2.0 第十节第 7 条红线「禁止越界实现：不做 AI 对话、不做自然度判定」；
- 违反「versionCode=2 零功能改动」指令；
- `judgeSay`=语义/自然度判定、`hint`=AI 提示，均属 Roadmap **v3**；
- 四个 API Key 硬编码进源码（APK 可反编译提取），为一票否决项。

代码未删，存档于 **`feature/llm-layer/`**（项目未启用 git，以目录代替 feature
分支），含 `llm.dart` 与 `README.md`（恢复前置条件）。将来 v1.1 评审通过后方可
重新接入。

---

## 七、llm 层 v1.1 规划（待办 · 未验收）

恢复前置条件（逐项满足后方可进构建）：

1. **判据纪律**：`judgeSay` 仅作**附加信息展示**，永不作为通过/失败判据，
   不得破坏既有 L1/L2/L3 降级链。
2. **静默降级**：必须定义**全部 provider 失败时**回到 Text Match / L3 的降级行为；
   任一网络异常不得阻断 Say 步主流程。
3. **密钥政策（硬性）**：四个 API Key **不得硬编码进源码 / 打包进 APK**
   （APK 可反编译提取 = 公开配额）。须与 Azure Key 一致由用户在设置页自行填入
   （新增 provider 配置 UI，存于 Hive，不入源码）。
4. **有效性核验**：四个模型 ID 与 Key 的真实归属、配额、可用性须逐个验证
   （尤其 `agnes-2.5-flash` 的真实性与配额来源；当前 Key 疑似沙箱环境，可能随时回收）。
5. 恢复后单独发版（versionCode 递增），不复用 versionCode=2 测试夹具。

---

## 八、图标（已完成 · v2 验收版）

正式 launcher 图标已生成并打包：navy（`#14213D`）圆角底 + 由 cyan/teal 方块拼成的
对话气泡（右下缺一块 = "chunks" 概念）；由 `flutter_launcher_icons` 自动生成各密度
mipmap 与自适应图标（前景透明、背景色 navy）。源图见 `assets/icon/icon.png` 与
`assets/icon/icon_foreground.png`（程序化绘制，非默认模板），已含于 SHA `28f2d11d…` 包中。
