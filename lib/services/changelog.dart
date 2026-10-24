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
  '· 界面动效整体打磨：完成庆祝、播放/暂停切换、数字滚动、底部浮层进出场统一了节奏，慢放也不粗糙',
  '· 列表、卡片与按钮按下去有缩放反馈，首页播单/词块库/复习列表依次入场，不再一起蹦出来',
  '· 麦克风与通知改为先讲清用途再请求；不再一进播放页就悄悄要通知权限',
  '· 底部「磨耳朵」入口加了到期块角标：有到期才出现，点进去就是今日复习播单',
  '· 复制导出内容时按钮原地变勾并显示「已复制」，不再另外弹一条提示',
  '· 系统里打开「减少动态效果」后，App 内动画全部改为直接切换，庆祝也不再放',
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
