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
const List<String> changelogItems = [
  '· 自由造句提前解锁（掌握 10 块即可）',
  '· 手感升级：答对反馈 / 连对 Combo / 掌握盖章',
  '· 新增会话战报页，数据全部真实',
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
