# 1.9.1/4091 发布核验存档（ASR-234 自定义导入可用性 + 六步互通 · 2026-11-08）

## 发布事实
- 线上：**1.9.1 / 4091**。arm64 `9f545ff43d3e0fa89183cb2383488021b06906164fcdab03fa44449c1fbe7ffc`（60,474,403 B）· v7a 3091 `7a04f3ccbdf56c20199d1c52cd107e8c9bf3658203ce978659a9655b173eefb2`（48,750,181 B）· x86_64 6091 `e3d3db452530f2a46e5289468371e25b00172570512cfd14caad51765fed29bf`（66,566,008 B）。
- 链：`dev/1.9.0-userpack`（`1ee1978` ASR-234 → `c87480b` bump 1.9.1+2091 / 自检归档 / 包内清单）→ `9a7dba6` 线上清单+官网切 1.9.1 → merge main `f68b5c8` = **tag v1.9.1**（已 push）；
  releases 仓 `eba923c`：`apk/1.9.1/`（三包 + 4 片 + version.json + version-1.9.1.json + abi-manifest + facts），并把 `apk/1.9.0/` 收为上一代（arm64 + 4 片 + 清单，撤 v7a/x64；1.8.6 承重墙原样）。
- 三源清单逐字节一致（清单文件 sha256 = `8854b9a208c43cae4c141a3148f8bf802eef4200895bac5bf0e2eccc2a8c53cd`）：
  raw / Pages / jsDelivr 三处 `http=200` 同值；`spotcheck.sh 1.9.1 4091` **[抽验通过]**（part0 全文 sha `e00d8ca5…` = 清单声明）。
- purge 11 条 finished：app `version.json`、`docs/version.json`、`docs/index.html`；releases `apk/1.9.1/` 的 version/abi-manifest/facts/part0..3。
- `verify_release.py --apk app-arm64-v8a-release.apk`：**[通过] 0 硬失败 / 8 告警**（7 条=jsDelivr 分片 Range 拿不到 Content-Length 无法核 size、1 条=未用 GitHub Release 通道；均非阻断）。
- 包内清单按既有 pass A/B 约定留存：包内 sha `8f1f6deeb44d…`（pass A），线上 sha `9f545ff4…`（pass B）；非自指字段同值 = True。

## 门禁
- `flutter analyze` **0 issues**；`flutter test` **1079/1079** 全过。
- `release/selfcheck/selfcheck-1.9.1.json`：21 个模块零红，hints=22，v1.9.1/4091。
- `preflight_invariants.sh`：**FAIL=1 WARN=0**。唯一 FAIL 为红线 1「main 已含 user_package.dart」——这是 1.9.0 发布合并后即存在的结构性事实（证据：`71b3887` 的 main 已含该文件），本版按发布序列合并属设计内；未擅自改闸脚本，留待用户裁定红线语义（发布前 vs 发布后）。
  §8 清单自洽硬闸：main 底版 sha = 同代 arm64 实算 = `9f545ff4…`，通过。

## 本版交付（对着实装核过）
- **粘贴纯清单不再报死错**：识别 `1.` / `2)` / `-` / `·` 等序号清单，一键转成带 `front,back,module_name` 表头的 CSV 骨架（句子进 front、back 留空、模块名预填「我的词表」），不替用户翻译。
- 自定义模块接入**官方同一套六步闭环**（锚定→拆解→听辨→跟读→替换→开口），学完按 1/3/7/14 天进复习。
- **词块库**新增「我的模块」卡（包/块数/已掌握/开始继续学习与复习）；**磨耳朵**可顺序朗读导入句（只播放，不改进度/不排复习/不计官方数）。
- 包详情改真实进度 + 六步入口；删除包级联清理，官方模块不动。
- 付费门口径不变：只在「确认导入」拦墙；解析预览、已导入词表阅读删除与学习记录**永久免费**。
- 官方学习内容、判卷阈值、识别引擎、codes.json / secret / 码体：**零改动**；发布链两脚本 `build_license_release.sh`、`stage_release.py` 一字未动。

## 模拟器实测（本侧完成）
- x86_64 6091 覆盖安装（原 1.9.0 数据保留），首次启动弹「本次更新 v1.9.1」并列出六条更新语（s1）。
- 首页「我的模块」卡 → 导入页 → 输入框键入 4 行纯清单 → 解析：出现「看着像一份清单，可以一键转成模板骨架」（s7）→ 点「转成模板骨架（4 行）」得到 `front,back,module_name` 骨架 + 每行 front 已填 / back 留空 / 模块名「我的词表」+ 提示语（s8）。
- 证据截图：`scratch/smoke191/s1.png` … `s8.png`（scratch 不入库）。

## 明确没做的 / 待回执
1. **真机弹窗腿 4090→4091**（arm64 实体机）未闭环，等用户回执（版本号 + 机型 + 看到什么）。
2. **真实解锁码走通**未在真机执行；模拟器只验证了免费的解析/预览/骨架转换段。
3. **票5 真机三句**仍未回执；按预授权口径缺口记「发布后验收」，不阻塞本次上线。
4. 1.9.0 的 v7a/x64 已按「上一代只留 arm64」撤下；若要回滚到 1.9.0 的 v7a/x64 侧载版本需从 tag 重新出包（arm64 回滚不受影响）。

## 回滚
`bash tools/rollback_manifest.sh 1.9.1 1.9.0 --apply`（1.9.0/4090 arm64 `1639e9f2…`；清单/官网一分钟内指回，包不删）。
