# ASR-206 §一 核查入账结论（2026-11-03T19:31:32+08:00）
1. verify_release.py --apk 退出码 0，硬失败 0，告警 3 项（均为已知非阻断：包内自指指纹滞后一代 / model.parts[2] 长度法不可核 / 未用 GitHub Release 通道）。
2. 三源清单 3 轮 × 3 源 = 9 次全部 200，逐字节同值：sha256 前缀 8a6d4eac39489c07，16945B，versionName/Code=1.7.3/4073，apk sha=7523f47f4f24…，size=60201731。
3. Pages 源（dukekang0124.github.io）本渠道 3/3 命中，包体 Range 探测 Content-Range 总长 60201731 与清单一致 → 你侧抓取失败判为渠道侧偶发，非线上缺件。
4. jsDelivr 分片：Range 探测回 content-range 总长 6429799（其内部压缩存储长度，非文件真实长度）；全文下载 part0 = 15728640B，sha256 8d2da10d9db95f3b… 与清单逐字节一致 → 印证既有口径「jsDelivr 只信全文 SHA，长度法整体无效」。
5. 存档件：verify_release.txt（体检全文）、three_sources.txt（三源三轮 + 包体长度）。
6. 班次抽验：tools/spotcheck.sh 1.7.3 4073 → 三源 200 且逐字节同值、官网链与徽标已切、part0 全文 sha 一致（release/verify/1.7.3/spotcheck-班次1.txt，exit=0）。
7. 更正：19:52 那一轮报的 Pages ✗ 是我这侧脚本把 Pages 路径拼成 /Dukekang0124/chunkspoke-releases/…（正确是 /chunkspoke-releases/…）造成的误报，已修；线上 Pages 一直完好，你侧的抓取失败本渠道未能复现（累计 4 轮 12 次全 200）。
