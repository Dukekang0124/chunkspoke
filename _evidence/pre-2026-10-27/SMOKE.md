# WEB-W1-PRE 冒烟证据（2026-10-27）

构建：`tool/build_web.sh`（`flutter build web --release --no-web-resources-cdn --tree-shake-icons`）
托管：`python -m http.server 8137 --directory build/web` → `http://127.0.0.1:8137/`

## 一、页面与路由

| 证据 | 路由 | 结论 |
|---|---|---|
| `01-data-route.png` | `/#/data` | 数据中心五块板（导出/导入/清空 disabled 占位）；**本机存储：IndexedDB 可用** |
| `02-review-before-keys.png` | `/#/review` | 复习台占位卡 1/3，顶栏「今日已复习 0 块」 |
| `03-review-flipped.png` | `/#/review` | 空格翻面成功（`get up` → 「起床；站起来」） |
| `04-review-after-3-enter.png` | `/#/review` | 按 3（通过）+ Enter：卡跳到 2/3，本次已评 1，顶栏「今日已复习 1 块」 |
| `05-library.png` | `/#/library` | 词块库五列表头 + 诚实空态「内容包尚未接入」；计数跨路由保留 |
| `06-articles.png` | `/#/articles` | 沉浸阅读占位（24 篇未接入） |
| `07-settings.png` | `/#/settings` | 版本 0.9.0-web（预置骨架）／内容包未接入／数据位置 IndexedDB |
| `08-review-retry-1.png` | `/#/review` | 重建后复测：空格 + 1（重学）+ Enter，计数 1、卡 2/3 |

顶栏：品牌 +「网页版 Beta」+「今日已复习 N 块」；**无 streak / 积分 / 进度墙**。

## 二、IndexedDB（真实浏览器断言）

`indexedDB.databases()` + 打开库读 `objectStoreNames` 的返回：

```json
{"dbs":["chunkspoke_web@1"],"version":1,
 "stores":["chunks:id:[assetState,dueDate,tier,updatedAt]","events:event_id:[at]","kv:key:[]","meta:key:[]"]}
```

与方案 §六-1 一致：4 store、`schema_version=1`、chunks 四索引。

## 三、外链与字体

- 修前：CanvasKit 缺 CJK 字形 → 去 `fonts.gstatic.com` 拉 Noto Sans SC，本机 FastGithub 把该域重定向成自指循环 → 全站中文豆腐块（当时截图 console 有 300+ 条 `Failed to fetch` warn）。
- 修后：`assets/fonts/NotoSansSC-Subset.otf`（GB2312+ASCII 子集，1,988,784 B，OFL）随包加载；
  `performance.getEntriesByType('resource')` 中 `fonts.gstatic.com` 命中数 **0**，包内字体命中 1。
- 重建后 console 总消息数 **1**（仅引擎 debug 注入行），**0 error / 0 warn**。
- `<html lang>` 运行时为 `zh-CN`（显式 `locale: zh_CN` 前是 `en-US`）。

## 四、产物

| 项目 | 值 |
|---|---|
| `main.dart.js` | 2,157,900 B（gzip 640,863 B） |
| `canvaskit/canvaskit.wasm` | 7,284,602 B |
| `assets/fonts/NotoSansSC-Subset.otf` | 1,988,784 B |
| build/web 合计 | 42 MB |

## 五、App 树隔离

`diff -u baseline_cs_build.txt current_cs_build.txt` → 无差异（`APP_TREE_UNCHANGED=verified`），
当前快照 sha256 = `9e828e390292479e7f3b5cffec4533ea3b85ce9c5506f2d3af965697c340ce7f`
（分支 `dev/sandbox-153`、HEAD `1d4468e`，7 modified + 1 untracked 均为预置前既有）。
