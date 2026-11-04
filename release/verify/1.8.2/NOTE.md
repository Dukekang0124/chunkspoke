# 1.8.2 发布核验存档（ASR-209 识别判卷双层修复 · 引擎不换）

## 线上态（三源）

- 三源清单逐字节同值：sha256 前缀 `797fc289e1affd76`，`versionName=1.8.2`、`versionCode=4082`
  （raw / Pages / jsDelivr@main 三条 spotcheck 全绿）。
- 官网首页：下载链已指 `apk/1.8.2/`、版本徽标 v1.8.2、页脚 SHA 已换成主包 sha。
- 主包（arm64）`bf4a34cb6ab0795cd5a917c8df4f90384ae68f26f25c8d441b4253fb24f682bf` · 60,212,019 B。
- 分片：part0 `da6920da59fd…`（15,728,640 B，jsDelivr 全文 sha 已核）
  part1 `a4294a1f0b86…` / part2 `5f08acad401b…` / part3 `2f8f89fecd14…`（13,026,099 B）；
  4 片本地重算 == 线上清单逐条同值，重组哈希 == 整包（stage 时已断言）。
- 完整性交叉证明（本机网络被限速到 ~40 KB/s，整包 57 MB 逐字节回灌未完成，改用两条硬证据）：
  1) releases 仓 `git cat-file blob HEAD:apk/1.8.2/chunkspoke-latest.apk` 的 sha256
     == 本地构建包 sha256 == 清单 sha256（GitHub 存的就是这个字节流）；
  2) Pages 直链 HEAD 200 且 `Content-Length: 60212019` 与清单 size 完全一致。
- jsDelivr 整包 403（单文件 20 MB 上限，历史一致）；分片链 4 片均 200，客户端按分片回退。

## 三包与四闸

- arm64 4082（60,212,019 B，已上传）/ armeabi-v7a 3082（48,504,181 B，未上传，与 1.7.x–1.8.1 同口径）
  / x86_64 6082（66,303,624 B，已上传）；versionCode 全部 aapt 实测核对。
- 闸 1 不变量：1000 组随机完成序列 + 全部写入点矩阵全过。
- 闸 2 自检归档：`release/selfcheck/selfcheck-1.8.2.json` · 21 模块零红 · hints=22 · v1.8.2/4082。
- 闸 3/4 签名：证书 `3244b4f8af39a4fc…` == 线上基线（CN=Android Debug，热修不换签，覆盖安装不断）。
- 清单非自指字段（版本/号/url/urls/pageUrl/notes）包内 == 线上；secret 指纹 `cfa45132`（只出指纹）。
- `verify_release.py --apk`：**0 硬失败 / 2 非阻断告警**（自指指纹滞后一代 + 未走 GitHub Release 通道）。

## 门禁

- `flutter test`：**904/904 全过**。本版新增/改动：`test/phonetics_test.dart`（阈值定标 54 组）、
  `test/asr209_judge_test.dart`（两案重建 + 100 条扰动 + 反例分级）、`test/asr209_labels_test.dart`
  （内容包 21 个 theme 全覆盖中文）、`test/asr_enhance_test.dart`（+2 条热词）、
  `test/judge_parity_test.dart`（100 条对拍重生成，Python 镜像同步）。
- `flutter analyze`：0 error，仅历史 1 条 info（`lib/services/recording.dart:3:8` 多余 import）。
- Python 侧：`tools/test_asr_bench.py` 21/21 过（含混淆对/虚词表漂移守卫、夹具不过期）；
  `tools/validate_content_pack.py` 零红。

## 本版实装与实测结论

- A 判卷层（离线）：规范化（大小写/标点/撇号/数词↔数字/口语缩合）+ 三通道
  （字符串包含 → 词级模糊 → 音素 g2p 编辑距离，阈值 `kPhonRatio=0.85`，定标表见
  `release/ASR-209/音素阈值定标.md`）+ 分级 hit/band/fail；band 走「差一点，再录一遍不扣分」，
  不写失败、不占三次机会（连续 3 次后按普通失败记账）。
- B 识别层：**线上引擎不换**。517 句 Zira 实测：vosk small WER 0.0327；
  zipformer 20M 0.3320（空结果 59）；带目标热词 + beam search 0.1698（空结果 0）；
  whisper tiny.en 0.2598（紧卷边 0.0827）且体积 103,627,191 B（≈98.8 MiB）。
  闸门要求「WER 降幅 ≥50% 且 RTF<1」→ 三档全部不通过，数据与结论见
  `release/ASR-209/B-识别层实测.md`。
- 有效收益已落地：目标句作为热词下传增强引擎（`asrHotwordsFrom`），空结果 59→0、WER 0.332→0.170；
  不开增强包的用户路径零变化。
- §六：S0 标题补中文「生存英语」，不再与英文副标题撞名（内容包 21 个 theme 全覆盖，有单测）。
- §五 C 联网评判：**本波不实装**（指令定为可选、不阻塞发版）；设计登记见
  `release/ASR-209/C-联网评判-设计登记.md`。既有「AI 联网点评」开关只管自由造句点评，
  默认**开**（实装事实，与 §五「默认关」口径不同，按「指令与实装冲突以实装为准」明报）。

## 模拟器实测（emulator-5554 x86_64）

- 14:09 · 本机 1.8.1/6081 拉起后自动检查更新：logcat
  `[update] 本机 ABI 槽位 6 ≠ 清单槽位 4，不弹应用内更新`
  → 非 arm64 设备不会被推错包（守卫生效，截图 `shots/00-…png` 同时留下 §六 修复前的英文标题现场）。
- 14:21 · `adb install -r chunkspoke-x86_64.apk`（6081→6082）**覆盖安装成功**，
  `dumpsys package` 显示 `versionName=1.8.2 versionCode=6082`，进度不丢（已掌握 22 词块、沙盒 231+）
  → 同签名热更路径可用；启动后无 FATAL/AndroidRuntime 崩溃。
- §六 视觉复核：地图卡标题＝「生存英语」（`shots/01-…`）；关卡页顶栏主标题「生存英语」+ 小字副标题
  「Survival First」，两行不再相同（`shots/02-…`）。
- 仍缺：arm64 真机的 4081→4082 **应用内弹窗**腿（模拟器 ABI 槽位天然不弹，非缺陷）。
  真机按 `release/ASR-209/验收-真机复测.md` 逐条走。

## 回滚

- 分钟级：`bash tools/rollback_manifest.sh 1.8.2 1.8.1 --apply`（回滚目标 1.8.1/4081，
  sha `29c862966f38…`，包仍在原路径可用）。
- 红线：识别判卷类 P0（大面积误判）→ 清单退回，代码不回滚，下一版修。
