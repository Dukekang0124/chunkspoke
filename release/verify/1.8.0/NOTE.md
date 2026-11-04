# 1.8.0 发布核验存档（ASR-208 §三）

- 三源清单（raw / Pages / jsDelivr）逐字节同值：sha256 前缀 `0df4290517e717c5`，
  `versionName=1.8.0`、`versionCode=4080`；官网首页下载链与版本徽标已切 1.8.0。
- 主包（arm64）`4b7f7fff665801e831a60b496fb4bab6147fa2a53a1d9bd77a1b6613c6aa410e` · 60,211,623 B；
  分片 part0 全文 sha `5a096d97860c4be2…`（15,728,640 B），4 片重组哈希 == 整包。
- 三包：arm64 4080 / armeabi-v7a 3080（48,454,629 B）/ x86_64 6080（66,303,224 B）。
  releases 仓只上传两包（arm64 + x86_64），v7a 留在本地装配目录，与 1.7.x 口径一致。
- 四闸：不变量 1000 组 + 写入点矩阵 4 条全过；自检归档 21 模块零红（hints 22）；
  签名第四闸证书 `3244b4f8af39a4fc…` == 线上基线（CN=Android Debug，热修不换签）；
  清单非自指字段包内/线上一致。
- `verify_release.py`：0 硬失败，10 条非阻断告警（自指指纹滞后一代 + HEAD 无 Content-Length +
  未走 GitHub Release 通道，均与 1.7.3 同类）。
- 回滚预案就位：`bash tools/rollback_manifest.sh 1.8.0 1.7.3 --apply`（分钟级）。
