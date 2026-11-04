# 1.8.3/4083 发布核验存档（ASR-211 · 2026-11-04）

## 发布事实

- 线上：**1.8.3 / 4083**（arm64 主包 sha256 `8560e1ea2e35de4bd141c960b2b9a6087a15adc5f70f9e5c505e42f4f97bc8f7` · 60,212,339 B）。
  v7a 3083 `502611cfa3204ea4d2569734e2ae2182243c3fc3786487ffed8860e4e28a39db`（48,520,881 B）；
  x86_64 6083 `3ee6a6313a83c565504fd32aa6a2fe97b3b12fff2c5f9f01739d80e8d266b040`（66,369,480 B）。
- 提交链：dev/1.8.0-content `14bc996`+`3384e25`+`b0e3c57` → main 合并 `13da5ee` → 清单/官网切换 `8ff2659` = **tag v1.8.3**；
  releases 仓 `daf8804`/`5a26c6a`/`190a35c`（apk/1.8.3 两包+分片+版本档案，已推 origin/main）。
- 三源清单逐字节一致（Pages / raw / jsDelivr@main）：`1.8.3 4083`，清单文件 sha `abb88009468db0a2…`，
  整包 sha `8560e1ea2e35…`，part0 `91bf585b4d65…`；jsDelivr purge 3/3 finished（version.json、docs/version.json、docs/index.html）。
- 门禁：`flutter test` **945/945**、`flutter analyze` 0 error（1 条历史 info）、
  发版四闸全绿（不变量 / 自检零红 `selfcheck-1.8.3.json` 21 模块 hints=22 / 签名 `3244b4f8…` / 非自指清单同值）；
  `spotcheck.sh 1.8.3 4083` 抽验通过；`verify_release.py --apk` **0 硬失败 / 8 非阻断告警**
  （告警全部是 HEAD 拿不到 Content-Length 的 CDN 侧现象 + GitHub Release 通道已废弃跳过资产检查；
  分片字节数已用 Pages HEAD 逐一核过：15728640×3 + 13026419）。
- 完整性硬证据：releases 仓 `git cat-file blob origin/main:apk/1.8.3/<包>` 的 sha256 == 本机终包 == 清单值（三包全部命中）；
  Pages 三链 HEAD 200 且 Content-Length 与清单 size 同值。本机→GitHub 均速实测 ~12 KB/s，整包逐字节回灌留到手机侧完成。

## 模拟器腿（x86_64，本机自测）

- `00_before_home.png`：升级前 1.8.2/6082 的真实数据基线 —— 已掌握 22 词块 · 沙盒 231+ · 生存 0/30 · 打招呼 100%。
- `adb install -r chunkspoke-x86_64.apk` → Success；`dumpsys package` = **versionName=1.8.3 versionCode=6083**。
- `01_after_home.png`：覆盖安装后同一份数据一字不差（22 词块 / 231+ / 0/30 / 100%），进度未丢。
- `04_settings_bottom.png`：设置页页脚 **ChunkSpoke v1.8.3**（kExportAppVersion 与 pubspec 同步生效）。
- 应用内更新腿：logcat `[update] 本机 ABI 槽位 6 ≠ 清单槽位 4，不弹应用内更新`
  —— 与 1.8.2 同口径的**预期静默**（线上清单以 arm64 为主包），不是缺陷；
  启动自动检查与设置页手动「检查更新」两条路径都验证了同一守卫。
  ⇒ **arm64 真机的 4082→4083 弹窗腿仍是缺口**，老板侧载 1.8.3 后即闭环（侧载直链见 `release/ASR-211/真机闸门-回执单.md` 第五节）。

## 本版交付（ASR-211 七件）

判卷撇号缩合归一（案1 落「差一点」不扣分，course↔cross 不放行；案2 钉住仍 fail）·
`:258` 读取点收口 + 块内书签只由锚定会话写 · 自愈四时机（冷启动/回前台/进模块/诊断一键修复）·
自检口径改「台账 ⇄ 渲染值」+ 孤儿行与跳块清单进导出 · 不变量矩阵进 CI（写入点×读取点登记表）·
跳块 UI「第 X 块待通过 · 已掌握 N/M」+ 补练未通过块入口 · 清单三份同写 + 真人麦克风 20 句评测集预置。

## 回滚

`bash tools/rollback_manifest.sh 1.8.3 1.8.2 --apply`（1.8.2/4082，sha `bf4a34cb…`）。
红线：进度/判卷类 P0 ⇒ 分钟级退回。
