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
  '· 磨耳朵按难度分档：A1 / B1 / C1 自己挑，没有测试也没有门槛；新增 6 篇（打招呼、问路、便利店、职场续篇、机场改签、电台独白），共 16 篇',
  '· 每一档自带默认语速（A1 慢到 0.75x，C1 到 1.25x）；你手动调过的速度会按档记住，换档不串味',
  '· 新增「讲解版」：在含未掌握词块的句子后插入讲解，端上合成、与正文同音色；可随时跳过或切回原版，讲解只看只听，不写学习进度',
  '· 今日复习播单：首页把含到期块的篇目串成播单，播放时到期块琥珀脉动，点一下直接进复习',
  '· 播放页加了「本文 N 块」横滑条、句级轻跟读（只跟读不计进度）和译文开关；词块库标出块来自哪篇文章，可按磨耳朵来源筛选',
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
