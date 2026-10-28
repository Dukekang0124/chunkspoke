# ChunkSpoke 网页版 Beta 0.9.0 · 发布记录与公告物料（2026-10-27）

- 版本：`0.9.0-web`（发布集 43 件 / 43,013,996 B，gzip 后首屏见 §3）
- 访问地址：**<https://dukekang0124.github.io/chunkspoke/web/>**
- 官网入口：<https://dukekang0124.github.io/chunkspoke/#web>（导航「网页版」+ 页面「网页版 Beta」卡片）
- 版本清单：<https://dukekang0124.github.io/chunkspoke/version_web.json>

## 1. 发布路径（一版一路径）

| 步 | 内容 | 结果 |
|---|---|---|
| 产物 | `releases` 仓 `web/0.9.0/` + `sha256-manifest.json`（逐件 sha256+字节）+ `version_web.json` | commit `4869f70`（前置 `fba7182`/`3114646`/`4b48a44`） |
| Pages | 站点仓 `docs/web/` 全量产物 + `docs/version_web.json` + 根 `version_web.json` | commit `b7c3c02` |
| 官网 | 导航「网页版」+ `#web` 卡片 + `.web-beta` 样式 | 同 `b7c3c02`（入口文案在 `e4aac28`/`0dc1e86`） |
| 源码 | `web-app/` 独立仓库 `web` 分支 | 已推送 `a29fd1f` |
| purge | jsDelivr 目录 + 关键单文件共 15 条 | 首轮 14 `finished` + 1 条连接重置，单条重跑 `finished` |

发布集**剔除** `.last_build_id`（Flutter 工具链内部构建标记，`web-app/.gitignore` 亦排除；GitHub Pages 对点开头文件返回 404，留在发布集里会让逐件校验出现假阴性）。

## 2. 线上复验（指令 §二-5 六项）

| 项 | 判定 | 数据 |
|---|---|---|
| 访问 200 | **过** | `/chunkspoke/web/` → 200（gzip，`Content-Length: 1465`） |
| 逐件 SHA | **过** | **五源 43/43 逐字节一致**（Pages / jsDelivr 站点 / raw 站点 / raw releases / jsDelivr releases）；见 [sha_verify_5src.json](sha_verify_5src.json) |
| 入口点击 | **过** | 官网页「打开网页版 →」→ URL 落到 `/chunkspoke/web/` |
| 控制台 0 错误 | **过** | 官网页 0、网页版 0；`pageerror` 0；失败请求 0 |
| 复习一张卡 | **过** | 「新学」→ 空格翻面 →「已认识，加入复习」 |
| 导出/导入往返 | **过** | 导出 `schema_version=1`（chunks=1 / events=1）→ 导入预览「预计新增」→ 合并导入「导入完成」 |

外部请求面：**全程只命中 `dukekang0124.github.io` 一个主机**（24 个请求），无第三方域名 → 红线②③在线上同样成立。

`content-encoding` 复核（D-5 闭环）：Pages 对 `index.html`、`main.dart.js`、`flutter_bootstrap.js`、`canvaskit/chromium/canvaskit.wasm`、`assets/.../chunks.json` 均下发 **gzip**。

### 2.1 线上首屏实传（`Accept-Encoding: gzip` 下 `%{size_download}`，非本地重算）

按 `_evidence/.../size/firstscreen_multi.txt` 记录的请求集逐件实测线上字节（[firstscreen_live.json](firstscreen_live.json)，脚本 [measure_live_firstscreen.py](measure_live_firstscreen.py)）：

| 口径 | 线上实传 | 本地 zlib-9 估算（§SMOKE 2.1） | 差 |
|---|---|---|---|
| Chromium（13 件） | 3,440,629 B = **3.28 MiB** | 3,421,965 B = 3.26 MiB | +0.5% |
| Firefox（12 件） | 4,304,588 B = **4.11 MiB** | 4,288,710 B = 4.09 MiB | +0.4% |
| 其中引擎（canvaskit） | 2,108,191 / 2,969,240 B | 2,107,921 / 2,969,453 B | ≈0 |
| 其中应用+内容 | 1,332,438 B = **1.27 MiB** | 1,314,044 B = 1.25 MiB | +1.4% |

结论不变：**总量口径未过 3 MB（D-1），应用+内容口径 1.27 MiB 过**；线上比本地估算高约 0.5%，是 Pages 的压缩级别与 zlib-9 的差别，不影响任何判定。逐件 sha256 均与清单一致。

## 3. 种子群公告草稿（只写已实装）

> 【ChunkSpoke 网页版 Beta 开了】
> 不用装 App，浏览器打开就能用：**<https://dukekang0124.github.io/chunkspoke/web/>**
> 现在能做的：487 个词块库（可按 T0/T1/T2 层级筛、只看已学、搜英文或中文，表里带频次排名）、24 篇分级文章阅读（中英双栏 + 词块高亮）、键盘复习（空格翻面，1/2/3 三档）、把进度导出成 JSON 备份、也能导回来。
> 暂时**没有**的：跟读打分、AI 点评、句子朗读、通知提醒——这些还在 App 里，网页版没做，页面上也写清了。
> 数据**只存在你这台电脑的浏览器里**，不上传、不注册账号；换浏览器或清缓存前先「导出」。与 App 的数据互通还在开发，两边进度目前各算各的。
> 建议用**桌面浏览器**（Chrome / Edge / Firefox），手机端首屏加载会比较久。
> 遇到问题直接回这条消息，或在 https://github.com/Dukekang0124/chunkspoke/issues 提一条。

**B4 自检**：全文无「即将上线」承诺；无评分/账号/云同步字样；「互通还在开发」为事实陈述（App 侧 JSON 通道归 1.5.10 / 议题 #209）；体积与性能只写「建议桌面浏览器」「手机端首屏较慢」，不写具体分数（移动 Lighthouse 70 / 首屏 3.26 MiB 属内部偏差 D-1/D-2，对外不引用）。

## 4. 三分钟教程（三行版）

1. 打开 <https://dukekang0124.github.io/chunkspoke/web/> → 首页看「487 块 / 24 篇」，顶栏「今日已复习 0 块」是你的本机进度。
2. 点「复习」→「新学」→ 按**空格**翻面看中文 → 按 **1**（重学）/ **2**（保留）/ **3**（通过）；想先看用法就点「阅读」任选一篇，中英双栏、词块已高亮。
3. 换电脑或清缓存前点「数据」→「导出」存一份 JSON；回来点「选择文件」→「合并导入」即可续上（同一条进度按较新时间取，不会越导越退）。

## 5. 遗留与下一步

- **金丝雀插队权不变**：用户说「OPPO 已连」立刻暂停本冲刺（截止 ≈2026-10-28 19:25）。
- **11-02 硬冻结仍有效**：网页版已上线，该条款对本波的目标（不拖住 1.5.9）已达成；1.5.9 于 11-02 开工不变。
- 反馈通道：种子群回复 + GitHub Issues（公告已含）。
- 对外不宣称 App 互通；待 1.5.10 JSON 通道落地后再改口径。
