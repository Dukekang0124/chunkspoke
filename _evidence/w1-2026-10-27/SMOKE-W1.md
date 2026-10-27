# SMOKE-W1 · ChunkSpoke 网页版 0.9.0 验收证据

- 日期：2026-10-27
- 版本：`0.9.0`（`version.json` `build_number=1`）
- 范围：指令 WEB-W1-GO §一 完工冲刺的 7 项验收门
- 证据目录：`web-app/_evidence/w1-2026-10-27/`（本文件与之同级）

---

## 0. 结论摘要（先看未过的）

| # | 验收门（方案 v1.1 §七） | 判定 |
|---|---|---|
| 1 | 三浏览器 × 五路由冒烟；导出→清空→导入→逐字段 diff 为空 | **过** |
| 2 | Lighthouse Performance（75 硬底线） | **部分过**：桌面 93 过；移动模拟 **70 未达 75** |
| 2b | Lighthouse Best Practices ≥ 90 | **未过**：81（全部为引擎/构建产物项，应用侧不可修） |
| 3 | 首屏 < 3 MB gzip | **未过（总量口径）**：Chrome/Edge 3.26 MiB、Firefox 4.09 MiB；**应用+内容口径 1.25 MiB 过** |
| 4 | 六条红线逐条留证 | **过** |
| 5 | `dart analyze` 0 / `flutter test` 全绿 / `build` 0 错误 | **过** |
| 6 | 与 App 对拍 due_date 序列逐条相同 | **过**（100 次判定 0 不一致） |

**一句话**：功能、数据、红线、可测性全过；三条未过项全部落在 **CanvasKit 引擎基线**（`canvaskit.wasm` 单文件 gzip 2.01 MB / Firefox 2.83 MB）上，与内容接入、业务代码无关。按裁定⑤「一轮为限」，本轮优化已用掉（见 §3），剩余为引擎固定开销。

---

## 1. 构建与产物

| 项 | 值 |
|---|---|
| 工具链 | Flutter 3.47.5 / Dart 3.13.4（`/d/tools/flutter/bin`） |
| 构建命令 | `bash tool/build_web.sh` → `flutter build web --release --no-web-resources-cdn --tree-shake-icons` |
| 产物 | `web-app/build/web/`，44 个文件，42 MB |
| `version.json` | `{"app_name":"chunkspoke_web","version":"0.9.0","build_number":"1","package_name":"chunkspoke_web"}` |
| 内容包 | 24 篇 / 487 块（`assets/content/{articles,chunks}.json`，包版本 1.2.0） |
| 字体子集 | `NotoSansSC-Subset.otf` 1368 字 / 352,736 B（脚本：`tool/subset_cjk_font.py`） |

关键产物 sha256（全量见 [size/build_sha256.txt](size/build_sha256.txt)）：

| 文件 | sha256 |
|---|---|
| `index.html` | `30f9f4bec6e82a3a9dc1c2e1410d2cabc5d87b686c5af7bd830efe0b4361be92` |
| `main.dart.js` | `2be828448b20b7679e0812a635072e0990b6e7c8c5418eff8540ea287e99bdbc` |
| `flutter_bootstrap.js` | `a4a0d8eccd12a95767afef7b094bfa1bb52b973769c25d39e43f44a44341f883` |
| `canvaskit/chromium/canvaskit.wasm` | `ae8ff1d858140f7b1300ced3fa89fb8c9dce0a400a0f4f1e11f6dcfb3315fdcf` |
| `assets/assets/fonts/NotoSansSC-Subset.otf` | `7da99e5b39545abc4b9b5757d2201b83e1080eff9b260b844e6f4e89a47e1832` |
| `assets/assets/content/chunks.json` | `4af5a566ee6a8b12746d16d9e193762e8e2c7b743d875aaaf13a12832101d04f` |
| `assets/assets/content/articles.json` | `5c1d69f4df2f4f4ddf91007139f1c3493326bed89425e2dc5e2f494f443bd8cb` |
| `version.json` | `c7a1a12740086c927b55f4f514866c7d483eba727e4fa13a634de2635237bd4b` |

**今日一并清掉的 B4 项**：`lib/screens/settings_screen.dart` 仍写着「0.9.0-web（预置骨架）/ 内容包尚未接入」，且 `/settings` 路由在 UI 上无任何入口 —— 属「写了没实装的东西」，已删除该页与路由（现存五屏：门户 / 词块库 / 阅读（含阅读器）/ 复习 / 数据）。

---

## 2. 体积门（§七 预算表逐行对账）

测法：Playwright 拦截首屏实际请求集（13～14 个文件），再逐文件 `zlib.gzipSync(level=9)` 计权。原始记录 [size/firstscreen_multi.txt](size/firstscreen_multi.txt)。

### 2.1 Chromium（Chrome 155 / Edge 156，两者请求集完全一致）

| 件 | 目标 | 实测 raw | 实测 gzip | 判定 |
|---|---|---|---|---|
| `main.dart.js` | ≤ 1.6 MB | 2,957,222 | **847,970（0.81 MB）** | 过 |
| CanvasKit（js + wasm） | 与字体合计 ≤ 1.0 MB | 5,515,032 | **2,107,921（2.01 MB）** | **破（单此一项即超线）** |
| 字体合计（Noto 子集 + 图标 + Roboto 回退 + Cupertino） | — | 534,776 | 398,999（0.38 MB） | — |
| 首屏 assets（chunks + articles + FontManifest + favicon） | ≤ 0.4 MB | 267,795 | **60,415（0.058 MB）** | 过 |
| 其余静态（index.html + flutter_bootstrap.js） | — | 15,665 | 6,660 | — |
| **首屏合计** | **< 3 MB** | **9,290,490** | **3,421,965（3.26 MiB）** | **破** |
| 其中：应用+内容（去掉 canvaskit/） | — | 3,775,458 | **1,314,044（1.25 MiB）** | 过 |
| 其中：内容 JSON 单独 | — | 266,513 | 59,403（2% 首屏） | 过 |

### 2.2 Firefox（142.0.1，走非 chromium 版引擎）

| 项 | raw | gzip |
|---|---|---|
| CanvasKit（js 86,987 + wasm 7,284,602） | 7,371,589 | 2,969,453 |
| 首屏合计（14 个文件） | 11,152,339 | **4,288,710（4.09 MiB）** |
| 应用+内容（去引擎） | 3,780,750 | 1,319,257（1.26 MiB） |

### 2.3 破线归因与处置

- **不是内容接入造成的**：全量 487 块 + 24 篇只占 59,403 B gzip，是首屏的 **1.7%**。指令 §一-1 给的补救手段「超了就按需切 `/web/content/`」在算术上无效 —— 把内容全砍到 0 仍剩 3.36 MB / 4.23 MB。
- **是引擎固定基线**：`canvaskit.wasm` 单文件 Chromium 2.01 MB、Firefox 2.83 MB。方案 §七 预算表「CanvasKit + 字体 ≤ 1.0 MB」这一行在写方案时未实测，**是计划假设错误，不是实施偏离**；`--no-web-resources-cdn` 只解决「从哪加载」，不解决「多大」。
- **渲染器切换不可用**：`--wasm`（skwasm）需要 `crossOriginIsolated`（COOP/COEP 响应头），GitHub Pages 无法下发此类头，切过去会直接在线上不可用。
- **未做**：内容切分（无效）、skwasm（不可用）、再压字体（CFF→glyf 至多省 ~150 KB，占 4%，且需重跑三浏览器渲染走查）。**按裁定⑤「一轮为限」，到此为止，记偏差。**

---

## 3. Lighthouse（首测 / 复测 / 终测三档全记）

Lighthouse 11.7.1（12.x 在本机 `@paulirish/trace_engine` 崩溃，已降级）。服务：本地 `python http.server`（无压缩；SW 见 D-7/D-8），`--headless=new`。全部报告：[lighthouse/](lighthouse/)。

| 轮次 | 形态 | Performance | a11y | BP | SEO | 备注 |
|---|---|---|---|---|---|---|
| 首测 | mobile 模拟 | **N/A** | 100 | 81 | 100 | CanvasKit 画在 canvas 上，无 LCP 候选 → 分数不可算 |
| 首测 | desktop | **N/A** | 100 | 81 | 100 | 同上（PWA 100） |
| 复测（本轮优化后） | mobile 模拟 | **70** | 100 | 81 | 100 | FCP 1.0 s / LCP 1.6 s / TBT 840 ms / CLS 0.013 / SI 21.3 s / TTI 44.1 s |
| 复测 | desktop | **93** | 100 | 81 | 100 | FCP 0.3 s / LCP 0.4 s / TBT 50 ms / CLS 0 / SI 3.0 s / TTI 7.3 s |
| 终测（本终包） | mobile 模拟 | **70** | 100 | 81 | 100 | FCP 1.0 s / LCP 1.9 s / TBT 820 ms / CLS 0.013 / SI 21.3 s / TTI 44.1 s |
| 终测（本终包） | desktop | **93** | 100 | 81 | 100 | FCP 0.2 s / LCP 0.3 s / TBT 50 ms / CLS 0 / SI 2.9 s / TTI 7.3 s |

明细：[lighthouse/lh_summary_final.txt](lighthouse/lh_summary_final.txt)。

**首测为什么是 N/A**：CanvasKit 首帧前页面只有 canvas，浏览器没有 LCP 候选元素，Lighthouse 直接给 `performance: null`。这本身也暴露了真实体验问题——首帧前是纯黑屏。

**本轮唯一优化**（裁定⑤允许的一轮）：
1. `web/index.html` 增加 HTML 层启动提示 `#boot-hint`（「正在加载学习内容…」），`flutter-first-frame` 事件触发即移除。既解决首帧前黑屏，也给 Lighthouse 一个真实 LCP 候选，使分数可算。
2. 字体子集化（1368 字，352 KB）+ `--tree-shake-icons`（MaterialIcons 1.6 MB → 8.9 KB）在此前已完成，不再计为一轮。

**复测后仍有的三项（归因明确、应用侧不可修）**：
- **移动 70 < 75**：移动模拟把 9 MB 首屏放到 1.6 Mbps RTT 150ms 上，TTI 44.1 s、SI 21.3 s 全是**下载+编译引擎**的时间。桌面 93 说明应用代码本身不慢。Beta 目标形态是桌面浏览器，此项按「记偏差」处置，并在官网入口注明「建议桌面浏览器」。
- **BP 81 < 90**：两项扣分全在产物：`deprecations`（`IntlV8BreakIterator` 在 `main.dart.js` 内，dart2js 生成）+ `valid-source-maps`（`main.dart.js`/`canvaskit.wasm` 无 sourcemap、`flutter.js.map` 404）。补 sourcemap 会让发布包 +5 MB 以上，得不偿失，故接受。
- **a11y 100 / SEO 100**：已达标。

---

## 4. 三浏览器冒烟 + 导出清空导入对拍

### 4.1 冒烟（脚本 `smoke.mjs`，结果 [smoke/smoke_summary.json](smoke/smoke_summary.json)）

| 浏览器 | 版本 | 9 步全过 | console errors | page errors | 外部资源命中 |
|---|---|---|---|---|---|
| Chrome | 155.0.8059.86 | 是 | 0 | 0 | **0** |
| Edge | 156.0.4314.42 | 是 | 0 | 0 | **0** |
| Firefox | 142.0.1（Playwright） | 是 | 0 | 0 | **0** |

九步：门户（487 块 / 24 篇）→ 词块库（五列 + 频次排名）→ 阅读列表 → 阅读器（双栏 + 「App 内可用」）→ 复习「新学」一块 → 数据页 → 导出 → 导入预览（「预计新增」）→ 合并导入（「导入完成」）。
截图 27 张：`smoke/smoke_{chrome,edge,firefox}_{1..9}_*.png`。日志尾部：`SMOKE RESULT: PASS`（[smoke/smoke_run.log](smoke/smoke_run.log)）。

### 4.2 导出 → 清空 → 导入 → 逐字段 diff（脚本 `roundtrip.mjs`）

方案 §七-1 要求「脚本化，不靠肉眼」，单独补测：

| 步骤 | 观测 |
|---|---|
| 新学一块（造状态） | 页面出现「已认识」 |
| 导出 A | `chunks=1`，`events=1` |
| 清空（双重确认：继续 → 确认清空） | 「本机学习数据已清空」，头部「今日已复习 0 块」 |
| 清空后再导出 C | **`chunks=0`，`events=0`**（证明清空真的落库） |
| 导入 A → 合并导入 | 「导入完成」 |
| 再导出 B | `chunks=1`，`events=1` |
| **A vs B 深度逐字段 diff** | **0 处差异**（仅排除 `exported_at` 每次必然变、`device_tag` 清空后按设计重生成） |

记录：[roundtrip/roundtrip.log](roundtrip/roundtrip.log) / [roundtrip/roundtrip_summary.json](roundtrip/roundtrip_summary.json)；截图 4 张 `roundtrip_*.png`。

### 4.3 与 App 的 SRS 对拍（§七-6）

方法：独立脚本 `/d/tmp/parity/parity.dart` **直接 import 两端真实逻辑文件**——App 侧 `lib/services/chunk_asset.dart` + `review_scheduler.dart`（`/d/cs_build` HEAD `1d4468e`，只读），Web 侧 `lib/data/review_rules.dart`；按方案 §六-2 的三档映射（`3 通过` = `reviewPass`+`nextDue`；`1 重学 / 2 保留` = `deferReview` 语义 `+1d`）跑矩阵。

- 规模：20 块（15 块从「巩固中 stage 0」起、5 块从「需重修 + 回退点已巩固 stage 1」起），单块最多 6 步，**共 100 次到期时间比对**
- 结果：**0 处不一致**（[parity/parity_run.txt](parity/parity_run.txt)，脚本存档 [parity/parity.dart](parity/parity.dart)）
- 覆盖到的分支：首次 1d → 3d → 7d → 14d → 已掌握（due=0 停排）、保留 +1d 不动档、重学 +1d 不动档、重修通过回原位（interval 取回退档）

---

## 5. 六条红线逐条留证（方案 §八）

| 红线 | 证据 |
|---|---|
| **① 零账号** | 代码无 cookie / localStorage 身份 / 登录页：`grep -niE "cookie\|login\|signin\|auth\|password"` 仅命中 `device_tag`（本机随机串，存 IndexedDB `meta`，见 [lib/app/session.dart:87](file:///D:/写作工具/知识管理/01-Projects-项目/求职与作品集/03-作品集/chunkspoke/web-app/lib/app/session.dart#L87)）。冒烟全程未出现账号相关界面（9 张截图） |
| **② 零上传** | 纯静态：`build/web` 全部为文件，无后端。导出走 `Blob` + 临时 `a[download]`（[lib/platform/file_io_web.dart:8](file:///D:/写作工具/知识管理/01-Projects-项目/求职与作品集/03-作品集/chunkspoke/web-app/lib/platform/file_io_web.dart#L8)），导入走 `<input type=file>`。冒烟三浏览器 **外部请求命中 0**（含 favicon 级请求） |
| **③ 无遥测** | 无 analytics / 无第三方字体 / 无 CDN：`grep -niE "http\|analytics\|gtag\|sentry\|firebase\|gstatic"` 仅命中三处**注释**（解释为何不能用 gstatic）。`main.dart.js` 运行时无外链请求 = 冒烟 `external=0`。事件只落 IndexedDB `events`（环形缓冲 500 条，与 App `analytics_events` 同口径） |
| **④ 防焦虑** | 唯一对外数字「今日已复习 N 块」（[lib/app/shell.dart:67](file:///D:/写作工具/知识管理/01-Projects-项目/求职与作品集/03-作品集/chunkspoke/web-app/lib/app/shell.dart#L67)）；无 streak / 积分 / 进度墙 / 到期红点（`grep -niE "streak\|积分\|排名\|进度墙\|红点"` 只命中 `correctStreak` 这一 SRS 内部字段及其合并保护，不对外展示）；每日上限仍为 20 / 新学 6 |
| **⑤ B4 只写已实装** | 五屏全部可用（截图 1-6）；语音/AI 一律写「App 内可用」/「请使用 App」（6 处：[app_only_notice.dart:26](file:///D:/写作工具/知识管理/01-Projects-项目/求职与作品集/03-作品集/chunkspoke/web-app/lib/widgets/app_only_notice.dart#L26)、阅读器与列表中 4 处、词块库 1 处）；无「即将到来」之外的超额承诺。今日另删除 `/settings` 一页（内容包「尚未接入」为假、路由无入口） |
| **⑥ 无 AI 无录音** | `grep -rn "getUserMedia\|MediaRecorder\|AudioContext\|speech_to_text"` → **0 命中**；`dart:js_interop` 仅用于 `Blob` 下载与 IndexedDB（两处，见红线②） |

---

## 6. 门禁

| 门 | 命令 | 结果 |
|---|---|---|
| 静态分析 | `dart analyze` | `No issues found!`（[gates/analyze.txt](gates/analyze.txt)） |
| 单测 | `flutter test` | **37 passed**（[gates/test.txt](gates/test.txt)），含字体覆盖守卫、`styleFrom(textStyle:)` 回归守卫、复习键盘流、合并器 LWW |
| 构建 | `bash tool/build_web.sh` | `√ Built build\web`，0 错误（[gates/build.txt](gates/build.txt)） |

### 6.1 本轮修掉的一个真实线上级缺陷（留档）

现象：阅读器一进入就向 `fonts.gstatic.com` 发 4 个 woff2 请求（国内不可达 → 中文豆腐块 + CORS 控制台报错），直接违反红线③。
定位：在 `main.dart.js` 里给 `ai8`（缺失码点回调）打探针，抓到缺失码点 `21152/20837/22797/20064` = **加 / 入 / 复 / 习**，即按钮「加入复习」。
根因：`OutlinedButton.styleFrom(textStyle: TextStyle(fontSize: 11))` **整体替换**主题 TextStyle，解析后 `fontFamily` 变 `null` → CanvasKit 找不到中文字形 → 拉 Noto 兜底。
修复：字号下沉到子 `Text`（[lib/screens/articles_screen.dart:518](file:///D:/写作工具/知识管理/01-Projects-项目/求职与作品集/03-作品集/chunkspoke/web-app/lib/screens/articles_screen.dart#L518)）。
守卫：新增 [test/font_family_test.dart](file:///D:/写作工具/知识管理/01-Projects-项目/求职与作品集/03-作品集/chunkspoke/web-app/test/font_family_test.dart)，断言四种按钮字族均为 `NotoSansSC`，并显式记录「`styleFrom(textStyle:)` 会丢字族」这一坑；[test/font_coverage_test.dart](file:///D:/写作工具/知识管理/01-Projects-项目/求职与作品集/03-作品集/chunkspoke/web-app/test/font_coverage_test.dart) 保证子集始终覆盖 lib + 内容资产 + 入口页的全部非 ASCII 字符（本次即靠它抓到入口页注释新增的「基/帧」两字）。

---

## 7. App 树零改动断言

| 项 | 值 |
|---|---|
| 分支 | `dev/sandbox-153` |
| HEAD | `1d4468e328cec542a672d41be651f550fc22a974` |
| `git status --porcelain` 载荷 sha256 | `453b76409655ca9a5facbeda71e48a5c4d622a4602a50d103d7a4e8689377435` |
| 基线同项 | `453b7640…`（**逐字节相同**） |

文件：[app-tree/status_now.txt](app-tree/status_now.txt) vs [app-tree/baseline_status_only.txt](app-tree/baseline_status_only.txt)。本日所有改动均在 `web-app/` 内，App 树只读访问。

---

## 8. 偏差与已知问题（需带入 DDS 偏差日志）

| 编号 | 项 | 实测 | 归因 | 处置 |
|---|---|---|---|---|
| D-1 | 首屏总量 < 3 MB | Chrome/Edge 3.26 MiB、Firefox 4.09 MiB（应用+内容 1.25 MiB） | CanvasKit wasm 固定基线 2.01/2.83 MiB | 记偏差接受；内容切分在算术上无效，故不做 |
| D-2 | 移动 Lighthouse ≥ 75 | 70（桌面 93） | 移动模拟 1.6 Mbps 下 9 MB 引擎下载+编译 | 记偏差接受；Beta 面向桌面，入口注明「建议桌面浏览器」 |
| D-3 | Best Practices ≥ 90 | 81 | dart2js `IntlV8BreakIterator` 弃用 + 缺 sourcemap | 记偏差接受；补 map 会让包 +5 MB |
| D-4 | 移动 TTI / SI | 44.1 s / 21.3 s | 同 D-2 | 同上；不承诺移动端首载体验 |
| D-5 | 体积测法 | 本机 `python http.server` 无压缩 → 按 gzip level 9 解析计算 | — | 线上若由 Pages 下发 Brotli，实际传输应更小；**发布后必须复核 `content-encoding`** |
| D-6 | 终测未跑 PWA 类目 | 终测报告 `categories` 只有 perf/a11y/bp/seo（首测/复测含 pwa=100） | 终测命令用 `--only-categories` 限定了四个类目 | 该字段可复核：`lh_*_first` 有 pwa、`lh_*_final` 无；不影响 perf/a11y/bp/seo 四类结论 |
| D-7 | service worker 与缓存 | 构建**确实**产出 `flutter_service_worker.js`，且 `index.html` 注册（`serviceWorkerVersion: "724019375"`） | Flutter release 默认行为 | 非「无 SW」；发布后复核须用全新上下文/禁用缓存首载，并确认新版本 `serviceWorkerVersion` 变更后 SW 能更新，避免旧缓存盖住新包 |
| D-8 | 冒烟环境 | `127.0.0.1:8099`，无 gzip、无 CDN；`127.0.0.1` 属安全上下文，SW 会注册，但每次冒烟用全新上下文、首载未被 SW 接管 | — | 首屏请求集即真实网络请求集，「外部命中 0」仍是**严格**判定而非被 CDN 掩盖 |

---

## 9. 复现

```bash
export PATH="/d/tools/flutter/bin:$PATH"
cd web-app
dart analyze && flutter test && bash tool/build_web.sh
python -m http.server 8099 --directory build/web      # 本机服务
cd /d/tmp/w1e2e && node smoke.mjs                     # 三浏览器冒烟
node roundtrip.mjs                                    # 导出→清空→导入→diff
node loaded_multi.mjs                                 # 首屏请求集 + gzip 计权
./node_modules/.bin/lighthouse http://127.0.0.1:8099/ --preset=desktop --output=json,html --output-path=out/lh_desktop
cd /d/tmp/parity && dart run parity.dart              # 与 App 对拍
```
