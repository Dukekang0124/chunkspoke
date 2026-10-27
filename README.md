# ChunkSpoke 网页版（预置骨架）

词块库、沉浸阅读与复习台的网页端。学习数据存本机浏览器（IndexedDB），文件不出浏览器。

- **预置阶段**：只搭地基（壳 + 协议 + 存储 + 键盘流），不接内容、不接线落盘、未发布。
- 进度、钉版本、已知事项与断点续法见 [PRE-LOG.md](PRE-LOG.md)。
- 冒烟证据见 `_evidence/pre-2026-10-27/`。
- 方案见 `../11-产品规划/2026-10-26-ChunkSpoke-Web产品方案-v1.1.md`。

```bash
export PATH="/d/tools/flutter/bin:$PATH"
export PUB_HOSTED_URL=https://pub.flutter-io.cn
flutter pub get
dart analyze          # 本机 flutter analyze 分析服务器会崩，用 dart analyze
flutter test          # 32 条
bash tool/build_web.sh
```

`assets/fonts/NotoSansSC-Subset.otf` 是 GB2312+ASCII 子集（SIL OFL 1.1）。内容接入后如遇缺字，
用 `python tool/subset_cjk_font.py <NotoSansSC-Regular.otf> assets/fonts/NotoSansSC-Subset.otf` 重生成。
