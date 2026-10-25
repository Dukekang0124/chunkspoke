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
  '· 词块库升级为课程大纲：首批 100 个 T0 核心块，按频率、通用性、可浮现与产出价值四项标准选出',
  '· 词块卡新增 T0/T1/T2 分层、八大功能类筛选和频次排名，找块不用再翻整本',
  '· 磨耳朵新增 8 篇分级内容（A1–C1），先选核心块再成篇，T0 块全覆盖',
  '· 到期复习优先安排 T0 核心块；统计页新增「核心库覆盖 T0 x/100」，首页不显示进度',
  '· 等级完成页奖杯动效接入全局动效开关，系统开启「减少动态效果」时直接切换',
  '· 更新源回退别名改为 @main，官网同源主源不变',
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
