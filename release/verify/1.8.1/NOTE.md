# 1.8.1 发布核验存档（商业化转化链路 · 微信手动发码）

- 三源清单（raw / Pages / jsDelivr）逐字节同值：清单 sha256 前缀 `e0a6750a850b34c7`，
  `versionName=1.8.1`、`versionCode=4081`；官网首页下载链与版本徽标已切 1.8.1，页脚 SHA 已换。
- 主包（arm64）`29c862966f380458b8773aa4fb784cc98ba42f6597d3be407f8dd7149a54fb79` · 60,211,787 B；
  分片 part0 全文 sha `8bbfb26b532fe377…`（15,728,640 B），4 片重组哈希 == 整包。
- 三包：arm64 4081 / armeabi-v7a 3081（48,471,177 B，未上传，与 1.7.x/1.8.0 同口径）/
  x86_64 6081（66,303,388 B）；releases 仓只传 arm64 + x86_64。
- 四闸：不变量 + 写入点矩阵全过；自检归档零红；签名第四闸证书 `3244b4f8af39a4fc…` == 线上基线
  （CN=Android Debug，热修不换签）；清单非自指字段包内/线上一致；secret 指纹 `cfa45132`。
- `verify_release.py --apk`：**0 硬失败**，10 条非阻断告警（自指指纹滞后一代 + HEAD 无 Content-Length +
  未走 GitHub Release 通道，均与 1.8.0 同类）。
- 门禁：`flutter test` **885/885 全过**（含新增 `test/license_wall_wechat_test.dart` 8 条）；
  `flutter analyze` 0 error（仅 `lib/services/rectording.dart:3:8` 一条历史 info）。
- 本版只动转化链路：墙点价格行、购买说明 sheet（微信号 `kz910124` 一键复制）、设置页专业版卡片、
  免费区完成横幅。免费额度 167 块、内容、学习流程零改动。
- 回滚预案就位：`bash tools/rollback_manifest.sh 1.8.1 1.8.0 --apply`（分钟级）。
