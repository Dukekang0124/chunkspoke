# WEB-W1-PRE 预置日志

**定位：预置 ≠ 开工。** 本目录只是网页版地基，不构成 W-1 发布的前置变更，也不改变方案 v1.1 的任何裁定。

- 硬冻结：**2026-11-02**（观测数据出数或 1.5.9 开工令 → 立即停在当时的完成度，如实报 N/7）
- 金丝雀优先：用户一旦说「OPPO 已连」，预置立即挂起，转金丝雀会话；预置无进度要求
- 隔离：本目录是独立 git 仓库（分支 `web`），**零 import `package:chunkspoke_flutter`**，`D:\cs_build` App 树与基线逐字节一致

## 一、钉版本（实拉后钉死）

| 依赖 / 工具 | 版本 | 说明 |
|---|---|---|
| Flutter / Dart | 3.47.5 / 3.13.4 | `D:\tools\flutter` |
| `go_router` | **18.1.1**（精确钉，非 `^`） | 裁定④；`ShellRoute` + `context.go` |
| `web` | **1.1.1**（精确钉） | `package:web` 的 IndexedDB 绑定 |
| `cupertino_icons` | ^1.0.8 | 脚手架自带 |
| `flutter_lints` | ^6.0.0 | 脚手架自带 |
| 字体 | Noto Sans SC 子集（GB2312+ASCII） | `assets/fonts/NotoSansSC-Subset.otf`，1,988,784 B，SIL OFL 1.1；由 `tool/subset_cjk_font.py` 生成 |

构建：`bash tool/build_web.sh`（= `flutter build web --release --no-web-resources-cdn --tree-shake-icons`）

## 二、目录

```
web-app/
  lib/
    app.dart            MaterialApp.router（locale zh_CN、主题、启动 bootstrap）
    main.dart
    app/router.dart     GoRouter + ShellRoute；路由 / /library /articles /review /data /settings
    app/session.dart    AppSession：reviewedToday / storageError / store / bootstrap
    app/shell.dart      顶栏（品牌 +「网页版 Beta」+「今日已复习 N 块」）+ 五项导航 + 窄屏横幅
    data/vocab.dart     AssetState / ReviewGrade，枚举线名硬校验（中文标签、数字档位一律拒收）
    data/protocol.dart  交换文件 schema_version=1、ChunkExchange 9 字段、DataPackage 编解码
    data/merge.dart     LWW 合并、派生补齐、streak 只增、孤儿、事件去重与 500 上限
    data/review_rules.dart  1-3 三档映射（§六-2）、intervalsDays、事件构造、trimEvents
    storage/schema.dart      chunkspoke_web v1：chunks/kv/events/meta 四 store 与索引
    storage/records.dart     ChunkRecord / EventRecord 行模型（-1 ↔ null 返回位）
    storage/store.dart       ProgressStore 抽象 + MemoryProgressStore
    storage/store_factory_web.dart  IdbProgressStore（package:web）
    storage/store_factory_stub.dart 条件导入回退
    screens/*.dart      门户 / 词块库 / 阅读 / 复习 / 数据 / 设置
    ui/theme.dart       与 App 同值的 Web 常量（复制值，不 import App）
  test/                 32 条（协议/合并/复习规则/存储/键盘流）
  tool/build_web.sh     构建脚本
  tool/subset_cjk_font.py  字体子集脚本
  assets/fonts/         OTF 子集 + OFL 许可原文
  _evidence/            冒烟截图与 SMOKE.md
```

## 三、完成度：7/7

1. ✅ 脚手架 + go_router + 主题 token（`flutter create --platforms web` 等价结构；无 App 依赖）
2. ✅ IndexedDB schema 模块（4 store，schema_version=1，chunks 四索引）
3. ✅ 互通协议模块（9 字段含返回位两列；grade 只收 `retry|keep|pass`；mastered/`review_stage==4` 派生 `l4_self_eval=1`+`l2_one_try=1`；重学 = `stage` 不变 + `streak=0` + `due=+1d` 无回退）——32 条单测全过，含往返逐字段 diff 为空与返回位往返用例
4. ✅ 五路由 UI 壳 + 顶栏「今日已复习 N 块」（无 streak / 积分 / 进度墙）
5. ✅ 键盘流骨架（空格翻面 / 1-3 自评 / Enter 下一个），暂接 3 张占位卡
6. ✅ `dart analyze` 0 问题 + `flutter build web` 0 错误
7. ✅ 本轮 commit + 进度一行

`flutter analyze` 分析服务器在本机曾崩溃（exit 255），统一改用 `dart analyze` 出结论。

## 四、明确未做（按指令 §二）

- 内容接入（487 块 / 24 篇渲染）、复习逻辑与 IndexedDB 落盘接线、数据中心完整功能、Lighthouse 调优
- 任何发布动作：`releases/web`、Pages、purge、官网入口
- App 侧任何文件：JSON 通道归 #209 / 1.5.10，TXT 七小节一字未动

## 五、预置期已知事项（W-1 开工时处理）

1. **CJK 字体是硬依赖**：CanvasKit 缺中文字形时会去 `fonts.gstatic.com` 拉 Noto，该域在本机（FastGithub）与国内网络基本不可达 → 全站豆腐块。现随包带 GB2312 子集；内容接入后应用实际字集**重跑 `tool/subset_cjk_font.py`**，并复核体积门（§七）。
2. **URL 用默认 hash 策略**（`/#/review`）：静态托管零配置深链；若 W-1 发布改用 Cloudflare Pages 并想要干净路径，再切 PathUrlStrategy + `_redirects`。
3. 顶栏「今日已复习 N 块」**目前只在本会话内存中累加**，未接 `events`/`kv`；W-1 接线后改为读库。
4. `flutter_localizations` 未接：Material 自带文案仍是英文（暂不暴露给用户）；W-1 接入。
5. `pubspec.yaml` 版本 `0.9.0+1`，设置页展示 `0.9.0-web`；发布路径口径见方案 §十一（`web/0.9.0/`）。
6. IDB 在 `AppSession.bootstrap()` 里真实打开一次（数据页展示「本机存储：IndexedDB 可用」），保证实现不被 tree-shake；构建产物 `main.dart.js` 中 `indexedDB` 命中 1 次。

## 六、每轮收尾的 App 树断言

```bash
{ git -C /d/cs_build rev-parse --abbrev-ref HEAD
  git -C /d/cs_build rev-parse HEAD
  git -C /d/cs_build status --porcelain; } > /d/gtmp/webpre/current_cs_build.txt
diff -u /d/gtmp/webpre/baseline_cs_build.txt /d/gtmp/webpre/current_cs_build.txt
```

无差异 = App 文件零改动。基线快照 sha256 `9e828e39…c340ce7f`（分支 `dev/sandbox-153`、HEAD `1d4468e`，7 modified + 1 untracked 均为预置前既有）。

## 七、证据

`_evidence/pre-2026-10-27/`：7 张路由/交互截图 + `SMOKE.md`（IndexedDB 结构断言、外链 0 命中、console 0 error、产物体积、App 树比对）。
