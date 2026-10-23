/// A6：更新清单（changelog）动态生成。
///
/// 历史问题：标题硬编码「本次更新 v1.4.0」，升级到 1.4.2 后清单仍显示旧版本号，
/// 属「写死文案」。现将标题与内容改为由当前版本号（PackageInfo）动态生成，
/// 删除写死文案；新增单测断言标题含当前版本号。
library;

/// 标题前缀（不含版本号）。
const String changelogTitlePrefix = '本次更新';

/// 由版本号生成标题；单测据此断言「标题含当前版本号」。
String changelogTitle(String versionName) =>
    '$changelogTitlePrefix v$versionName';

/// 本次更新亮点（内容项，与具体版本号解耦的静态语料）。
/// 1.5.4 起写本版真实交付项；发版前须与对账表逐条核对，不得沿用上一版文案。
const List<String> changelogItems = [
  '· 新增「磨耳朵」页：10 篇场景文章（点餐 / 机场 / 职场 / 医院），2–3 分钟一篇，先听个耳熟',
  '· 支持后台播放与通知栏控制：上一句 / 播放暂停 / 下一句 / 关闭；来电打断自动暂停并记住续播点',
  '· 文章随学习进度成熟：词块按新块候选（蓝）→ 在学（琥珀）→ 已掌握（金）三级着色，只有走完复习才染金',
  '· 语音判定收口：识别原文逐字展示，通过与否另起一行，AI 参考说法分列',
];

/// 一条可展示的更新清单。
class Changelog {
  final String title;
  final List<String> items;
  const Changelog(this.title, this.items);
}

/// 由当前版本号构建完整更新清单。
Changelog buildChangelog(String versionName) =>
    Changelog(changelogTitle(versionName), changelogItems);
