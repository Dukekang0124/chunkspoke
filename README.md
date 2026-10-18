# ChunkSpoke Flutter (v2.0 · Phase 1)

真机验收版工程。本目录仅含 **Phase 1** 代码：FTUE + Map + Level 五步循环（LEARN / RECOGNIZE / BUILD / SAY / SWAP），评分走 **L3 自确认**（Phase 2 才接入本地 STT 与 Azure）。

## 关键约定（与方案一致）
- 所有词块 / 句子 / 中文释义均来自 `assets/content_pack.json`，UI 代码**零硬编码内容**。
- 内容包由 `gen_content.js` 生成（仅开发期工具，不参与 App 运行）：`node gen_content.js` 会校验并重建 `content_pack.json` 与 `content_table.md`。
- 固定深色主题，四色词块双重编码（颜色 + 形状）。
- 长按任意英文弹中文卡（3.5s 自动消失，计入提示率），禁用系统选择菜单。
- 无 Key / 断网 / 识别为空时，SAY 走 L3：显示 `Couldn't hear clearly. Tap if you said it.` + `I said it` / `I said it right`，`Next sentence` 永远可点。

## 构建步骤（在已装 Flutter stable + Android SDK 的机器上）
```bash
cd chunkspoke-flutter
flutter pub get
flutter create --platforms=android .     # 生成 android/ 与 gradle 包装，不会覆盖现有 lib/
```
生成后改 `android/app/build.gradle` 的 `defaultConfig`：
```gradle
minSdkVersion 24
```
（可选，Phase 2 需要）在 `android/app/src/main/AndroidManifest.xml` 的 `<manifest>` 内加：
```xml
<uses-permission android:name="android.permission.RECORD_AUDIO"/>
<uses-permission android:name="android.permission.INTERNET"/>
```
然后：
```bash
flutter build apk --release     # 产物：build/app/outputs/flutter-apk/app-release.apk
# 或直接连真机调试：flutter run
```

## Phase 1 自测要点（对照方案验收清单）
- [ ] 首启 30 秒内进 A 关；无注册 / 无水平测试。
- [ ] 走完 A 关五步，全程无中文整句翻译。
- [ ] 长按英文弹中文卡、3.5s 消失；（Me 页 Phase 3 才展示提示率，但计数已写入 Hive）。
- [ ] BUILD 拖错顺序词块回弹，无报错文案。
- [ ] SAY 点麦克风 → 波形 → 停止后出现 L3 自确认卡片（Phase 1 无 STT，正常）。
- [ ] `Next sentence` / `I said it` / `I said it right` 任意状态均可推进，不卡死。
- [ ] 完成 A 关 → 结算页 → 返回 Map，B 关解锁。
- [ ] 未解锁关点击有 toast；长按显示中文。

## 本机未做之事（受环境限制）
- 本机无 Flutter / Java，未能执行 `flutter analyze` / `build apk`。请在你机器上构建并粘贴任何编译报错，我来修。
- Phase 2（录音 + 本地 STT + Azure + 申诉链路）、Phase 3（掌握度四维 / 解锁 / Review / Me）、Phase 4（更新机制 + 视觉打磨 + release）按方案逐 Phase 推进。

## 更新通道与 jsDelivr 缓存处置

应用内自更新清单（`version.json`）主源走 `raw.githubusercontent.com`（即时生效），
`cdn.jsdelivr.net` 仅作清单兜底 + 服务分块/APK 大文件。jsDelivr 对 `@main` 有约 12h 缓存，
遇缓存事故（兜底源返回旧清单、分块 404/旧文件）用 purge 强制刷新：

```text
https://purge.jsdelivr.net/gh/<OWNER>/<REPO>@<branch>/<path>
```

完整发布流程、字段定义与 purge 判定见仓库根 `version_json_deploy.md`。
