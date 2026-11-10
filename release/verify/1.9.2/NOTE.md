# 1.9.2 / 4092 发版验证记录

日期：2026-11-10（线上切换与三源复验同日完成）

## 一、版本与产物

| 项 | 值 |
| --- | --- |
| 线上版本 | 1.9.2（arm64 4092 / v7a 3092 / x64 6092） |
| arm64 APK | 60,474,335 B · sha256 `6a6468f9cba6f5f1d5a8612bbe70c75de8b7484d010616c6d023705aeca91ab0` |
| armeabi-v7a | 48,815,645 B · sha256 `dc63fb9c7828f3a5fddb2d19440bbf8ea4f4999d58d8e741fbdbeb6dfe62b38e` |
| x86_64 | 66,631,472 B · sha256 `510a4e00415fd5984b296bc924fe76d7af4956b54899b15b74b7f46e93211311` |
| 分片 part0 | sha256 `e1169be39815f695c3f6a2e5e1c5ecfc9aa8330945c19738c6a933f8fe1b18bf`（15,728,640 B） |
| 清单 sha | `f677ed4645d797d8`（raw / Pages / jsDelivr 三源逐字节一致） |

pass A（包内 assets/version.json 自指纹）为 `c37175da`，落后一次构建；线上真值为 pass B `6a6468f9`——与既往各版一致的口径，`verify_release.py` 已按真值核对包内 versionCode 4092。

## 二、提交与标签

- dev/1.9.0-userpack：`e38f888`（粘贴任意文本 + 5 边界修复）→ `e08783c`（bump / 清单 / 自检归档）→ `23748d2`（线上清单与官网切 1.9.2）
- main：合并 `b08149f`，tag **v1.9.2**，已推送
- releases 仓：`a5ce56b`（上传 1.9.2 三 ABI + 4 片 + 清单）→ `09b40c6`（Pages 1 GB 裁剪）

## 三、门禁

| 门 | 结果 |
| --- | --- |
| `flutter analyze` | 0 issue |
| 全量测试 | 1090 绿（含 changelog 版本钉测、导入解析 35 例压力报告 + 6 条钉测） |
| 自检归档 selfcheck-1.9.2 | 21 项审计全一致、reds 0、needsAction false |
| `preflight_invariants.sh` | FAIL=1，为「main 已含 user_package.dart」结构性事实（1.9.0 起随包上线），脚本未改动，如实记录 |
| `verify_release.py` | [通过]：清单/三份副本一致、APK 真值、外部地址可达、Range 206、三源一致；8 项不阻断告警（parts 的 HEAD 不回 Content-Length、未走 GitHub Release 通道） |
| `spotcheck.sh 1.9.2 4092` | [抽验通过]（三源清单同 sha、官网徽标 v1.9.2、part0 全文 sha 相符） |

## 四、更新弹窗端到端（模拟器）

- 在已装 1.9.1（vc 2091）的模拟器上 `adb install -r -d` 覆盖安装 x86_64 6092；
- `dumpsys package com.chunkspoke.app` → versionName 1.9.2 / versionCode 6092；
- 首启弹出「本次更新 v1.9.2」，四条文案与 `changelogByVersion['1.9.2']` 完全一致，见 `01_update_dialog_6092.png`。

## 五、Pages 1 GB 上限处置

github.io 部署在首轮全量上传后一度整体 404；根因是发布站点体积（1,173,374,776 B）超过 GitHub Pages 1 GiB 限制。处置（`09b40c6`）：

- 删除 `apk/1.9.0/` 整代；
- `apk/1.9.1/` 只保留 arm64 整包 + 清单/manifest/facts，撤下 v7a、x64 与 parts；
- 发布站点体积降至 992,046,297 B。

处置后复验：`apk/1.9.2/version.json` 200、已删除的 `apk/1.9.1/chunkspoke-armeabi-v7a.apk` 404，证明新部署已生效；随后 spotcheck 与 verify_release 全绿。

回滚口径变化（如实）：当前可回滚到 1.9.1 的 **arm64 整包**（sha `9f545ff4…`，Pages/raw 均可下载），但 1.9.1 的 v7a/x64 与分片已不在线上，非 arm64 用户无法回滚到 1.9.1，只能前向修复。

## 六、边界与未做项

- 真机弹窗腿 4091→4092 未做（模拟器已过；真机不可代劳）；
- 真实解锁码端到端未做（不碰 codes.json / secret / 码体；此前演练码路径未用于本版真机）；
- 票 5（用户侧导入体验反馈）未开始；
- 官方学习内容、判卷阈值、识别引擎零改动（本版仅「我的英语本」导入链路）。

证据补充：`01_update_dialog_6092.png`；解析器边界证据见 `../userpack-arbitrary-text-192/`。
