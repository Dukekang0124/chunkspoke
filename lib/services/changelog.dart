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
  '· 朗读人声升级：新增 3 个自然人声音色包（清晰女声 / 温和女声 / 沉稳男声），按需下载，可试听、切换和删除',
  '· 音色包不占安装包体积；删除音色或关闭自然人声后，自动回到系统发音',
  '· AI 造句点评支持自定义模型：可选 GLM 预设，也可填任意 OpenAI 兼容接口',
  '· API Key 只加密保存在本机，不上传、不写日志；设置页新增连接测试与发送内容说明',
  '· 未配置 AI 时，六步学习、复习、解锁与磨耳朵照常可用',
  '· 修复：应用内更新只认本机 ABI 的安装包，32 位设备不再收到装不上的更新',
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
