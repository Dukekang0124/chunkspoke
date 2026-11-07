# 1.9.0/4090 发布核验存档（自定义词表导入 + 付费门 · 2026-11-07）

## 发布事实
- 线上：**1.9.0 / 4090**。arm64 `1639e9f2f855eccc…`（60,408,643 B）· v7a 3090 `c781ecef…`（48,684,417 B）· x86_64 6090 `968556f3…`（66,500,248 B）。
- 链：`dev/1.9.0-userpack`（ASR-233 付费门 + 第 5/6 步卡片 + D 轮）→ merge main `0a61271` → bump `d8e022a`（1.9.0+2090）→ 自检归档 `4ded0f3` → 清单/官网切换 `455b966` → main 合并 `b683355` = **tag v1.9.0**（已 push）；
  releases 仓 `apk/1.9.0/`（三包 + 4 片 + version.json + abi-manifest + facts，`7e80ef1`），旧代瘦身与沙盒 x64 清理 `c5e5786`。
- 三源清单逐字节一致（清单文件 `bec04bdcdc7eb2f9…`；其内 arm64 sha `1639e9f2f855eccc` / 60408643）：
  raw / Pages / jsDelivr 三处实测同值；purge 3/3 finished（`version.json`、`docs/version.json`、`docs/index.html`）；
  `spotcheck.sh 1.9.0 4090` **[抽验通过]**；`verify_release.py --apk` **[通过] 0 硬失败 / 1 告警**（告警=未用 GitHub Release 通道，非阻断）。
  注：releases 仓 Pages 镜像本次实测 **200**（长度与整包一致），此前 B-3「Pages 未启用、全部 404」的结论作废，按实测为准。
- 门禁：`flutter test` **1039/1039**、`flutter analyze` 0、`selfcheck-1.9.0.json` 21 模块零红（hints=22）、
  `preflight_invariants.sh` **FAIL=0 WARN=1**（WARN=清单本地差异，属 bump 轮允许项；§8 硬闸已对到新包 sha）。

## 本版交付（对着实装核过）
- **我的模块 · 导入自己的词表**：剪贴板粘贴 / 本机 CSV-JSON 文件 / 模板三入口；预览页逐块、模块名、错行全摊开，
  **解析与预览永久免费**；只在「确认导入」一步拦墙。
- **付费门**：`LicenseFeature.customImport` 经 `allows()` 判定；`hasFullAccess = isPro || legacyEligible`；
  未授权时库层 `UserImportResult.blockedByLicense()` 必填放行位、备份通道 `allowUserPackages=false`（不写 `userpkg.*` 档案）；
  **已导入词表的阅读、删除、学习记录永久免费**，老用户（grandfather）与已解锁用户不受影响。
- **诊断 → 我的模块**：档案与台账不一致、坏档案可见，一键修复覆盖；卸载应用随档案一起清（无孤儿行）。
- **第 5/6 步**接「机器不确定」卡片：候选 + 打字出口，失败屏整屏可滚。
- 官方学习内容、判卷阈值、识别引擎、codes.json / secret / 码体：**零改动**；发布链两脚本 `build_license_release.sh`、`stage_release.py` 一字未动。

## 明确没做的 / 待回执
1. **真机弹窗腿 4087→4090**（arm64 实体机）未闭环——本侧无法代劳，等用户回执。
2. **票5 真机三句**（用户执行）仍未回执；按预授权口径，缺口改「发布后验收」记账，不阻塞本次上线。
3. **真实解锁码走通一遍**（生产 secret 的码体）未在真机执行；本侧只有测试 secret 的沙盒 v4 与六组钉测证据。
4. 本版**未跑模拟器装机腿**：三源、抽验与门禁已全绿，「装上能跑」依赖第 1 条真机回执。

## 回滚
`bash tools/rollback_manifest.sh 1.9.0 1.8.6 --apply`（1.8.6/4087 arm64 `cdb867c8…`；清单/官网一分钟内指回，包不删）。
