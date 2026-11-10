// 1.6.0（LIC-1）· 输码页 + 墙点 sheet。
//
// 纪律：页内**不得自建校验逻辑**——解析/归一/校验全在 license_code.dart，
// 三态判定全在 license_state/license_gate；这里只做输入与呈现。
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../services/license_code.dart';
import '../services/license_gate.dart';
import '../services/license_state.dart';
import '../ui/theme.dart';

class LicenseActivateScreen extends StatefulWidget {
  const LicenseActivateScreen({super.key, this.gate});

  /// 测试可注入；生产为 null 时现建一个。
  final LicenseGate? gate;

  @override
  State<LicenseActivateScreen> createState() => _LicenseActivateScreenState();
}

class _LicenseActivateScreenState extends State<LicenseActivateScreen> {
  final _controller = TextEditingController();
  LicenseGate? _gate;
  bool _busy = false;
  String? _message;
  bool _success = false;

  @override
  void initState() {
    super.initState();
    _gate = widget.gate;
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit(LicenseState lic) async {
    if (_busy) return;
    final input = _controller.text;
    setState(() {
      _busy = true;
      _message = null;
    });
    // 先解析拿 nonce，再问白名单（三态），最后交给 LicenseState 落盘。
    final parsed = parseLicenseCode(input);
    WhitelistLookup lookup = WhitelistLookup.unavailable;
    if (parsed.ok) {
      final gate = _gate ??= LicenseGate();
      try {
        lookup = await gate.lookup(parsed.code!.nonce);
      } catch (_) {
        lookup = WhitelistLookup.unavailable;
      }
    }
    final result = await lic.activate(input, whitelist: lookup);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _success = result.ok;
      _message = result.ok
          ? (result.verifyState == kVerifyUnverified
              ? '已激活（暂时没连上清单，先按本地校验放行）。'
              : '已激活：${result.code!.edition} · 码尾 ****${result.code!.tail}')
          : result.message;
    });
  }

  @override
  Widget build(BuildContext context) {
    final lic = Provider.of<LicenseState?>(context);
    return Scaffold(
      appBar: AppBar(title: const Text('输入解锁码')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '解锁码是 20 个字符，以 CS 开头。空格和横线可以直接粘，不用自己删。',
              style: TextStyle(color: kTextSecondary, fontSize: 13),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _controller,
              maxLines: 3,
              minLines: 2,
              style: TextStyle(color: kText, fontSize: 16, letterSpacing: 1.2),
              decoration: InputDecoration(
                hintText: 'CSXXX-XXXXX-XXXXXXXXXX',
                hintStyle: TextStyle(color: kBorderStrong),
                filled: true,
                fillColor: kCard,
                border:
                    OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                TextButton.icon(
                  onPressed: () async {
                    final data = await Clipboard.getData(Clipboard.kTextPlain);
                    final text = data?.text ?? '';
                    if (text.isEmpty) return;
                    _controller.text = text;
                    setState(() {});
                  },
                  icon: const Icon(Icons.content_paste, size: 16),
                  label: const Text('粘贴'),
                ),
                const Spacer(),
                Text('${cleanLicenseCode(_controller.text).length}/20',
                    style: TextStyle(color: kTextFaint, fontSize: 12)),
              ],
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: kPrimary,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
                onPressed:
                    _busy || lic == null || _controller.text.trim().isEmpty
                        ? null
                        : () => _submit(lic),
                child: Text(_busy ? '校验中…' : '激活',
                    style: TextStyle(color: kOnPrimary)),
              ),
            ),
            if (_message != null) ...[
              const SizedBox(height: 16),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: kCard,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                      color: _success
                          ? kUnlocked.withValues(alpha: 0.6)
                          : kError.withValues(alpha: 0.6)),
                ),
                child: Text(
                  _message!,
                  style: TextStyle(
                      color: _success ? kUnlocked : kError, fontSize: 13),
                ),
              ),
            ],
            const SizedBox(height: 24),
            Text(
              '这台设备用于换绑的编号',
              style: TextStyle(color: kTextMuted, fontSize: 12),
            ),
            const SizedBox(height: 4),
            SelectableText(
              lic?.deviceId ?? '—',
              style: TextStyle(
                  color: kTextSecondary, fontSize: 12, fontFamily: 'monospace'),
            ),
            const SizedBox(height: 6),
            Text(
              '换手机或重装时，把这个编号发给发码人，可以把码迁到新设备。',
              style: TextStyle(color: kTextFaint, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}

/// 1.8.1（任务书 §〇）· 商业化转化链路的**文案单源**：价格、名额、微信号只在这里写一次，
/// 墙点 sheet / 购买 sheet / 设置页 / 结算横幅全部引用它，改价不用翻四个文件。
const String kWechatId = 'kz910124';
const int kEarlyBirdPrice = 68;
const int kStandardPrice = 128;
const int kEarlyBirdSeats = 200;

/// 墙点 sheet：G 关灰锁 / 口语日记入口共用。
/// 展示价格 + 加微信购买 + 输码入口，三按钮层级清晰（任务书 §二）。
Future<void> showLicenseWallSheet(
  BuildContext context, {
  required String title,
  required String detail,
}) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: kCard,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (ctx) => SafeArea(
      // 小屏/大字号时整张 sheet 可滚动，不让 Column 溢出（任务书只给静态高度会翻车）。
      child: ConstrainedBox(
        constraints:
            BoxConstraints(maxHeight: MediaQuery.sizeOf(ctx).height * 0.85),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 标题行
              Row(
                children: [
                  Icon(Icons.lock_outline, color: kPrimary, size: 18),
                  const SizedBox(width: 8),
                  Text(title,
                      style: TextStyle(
                          color: kText,
                          fontSize: 16,
                          fontWeight: FontWeight.w600)),
                ],
              ),
              const SizedBox(height: 12),
              // 正文说明
              Text(detail,
                  style: TextStyle(
                      color: kTextSecondary, fontSize: 13, height: 1.5)),
              const SizedBox(height: 14),
              // 价格行
              Container(
                width: double.infinity,
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  color: kPrimary.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: kPrimary.withValues(alpha: 0.3)),
                ),
                // 两行：360 宽手机上「¥68 + 名额 + 原价」单行放不下，会横向溢出。
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text('早鸟价 ',
                            style:
                                TextStyle(color: kTextSecondary, fontSize: 13)),
                        Text('¥$kEarlyBirdPrice',
                            style: TextStyle(
                                color: kPrimary,
                                fontSize: 20,
                                fontWeight: FontWeight.w700)),
                        const Spacer(),
                        Text('原价 ¥$kStandardPrice',
                            style: TextStyle(
                                color: kTextFaint,
                                fontSize: 11,
                                decoration: TextDecoration.lineThrough)),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text('前 $kEarlyBirdSeats 名 · 永久买断',
                        style: TextStyle(color: kTextMuted, fontSize: 12)),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              // 主按钮：加微信购买
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: kPrimary,
                    padding: const EdgeInsets.symmetric(vertical: 13),
                  ),
                  icon: const Icon(Icons.chat_bubble_outline, size: 18),
                  label: Text('加微信购买 ¥$kEarlyBirdPrice',
                      style: TextStyle(color: kOnPrimary, fontSize: 15)),
                  onPressed: () {
                    Navigator.pop(ctx);
                    showWechatPurchaseSheet(context);
                  },
                ),
              ),
              const SizedBox(height: 8),
              // 次按钮：已有码
              SizedBox(
                width: double.infinity,
                child: OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    side: BorderSide(color: kBorder),
                  ),
                  child: Text('我已有码，输入激活',
                      style: TextStyle(color: kTextSecondary, fontSize: 14)),
                  onPressed: () {
                    Navigator.pop(ctx);
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (_) => const LicenseActivateScreen()),
                    );
                  },
                ),
              ),
              const SizedBox(height: 4),
              // 三级按钮：先继续学（不骚扰：只在主动点墙时出现）
              Center(
                child: TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: Text('先继续学免费内容',
                      style: TextStyle(color: kTextMuted, fontSize: 13)),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

/// 购买说明 sheet：怎么加微信、怎么付款、怎么拿码（任务书 §三）。
/// 纯复制微信号，不嵌二维码图片。
Future<void> showWechatPurchaseSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: kCard,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (_) => const _WechatPurchaseSheet(),
  );
}

/// 购买说明 sheet 的内容体。
///
/// 做成有状态只为一件事：复制成功后按钮就地变「已复制」。
/// 模态 sheet 整张盖在 Scaffold 之上，SnackBar 会被它挡在下面 —— 真机上等于
/// 没有反馈，所以可见的确认必须画在 sheet 自己身上（SnackBar 保留给读屏播报）。
class _WechatPurchaseSheet extends StatefulWidget {
  const _WechatPurchaseSheet();

  @override
  State<_WechatPurchaseSheet> createState() => _WechatPurchaseSheetState();
}

class _WechatPurchaseSheetState extends State<_WechatPurchaseSheet> {
  bool _copied = false;

  @override
  Widget build(BuildContext context) {
    final ctx = context;
    return SafeArea(
      // 小屏/大字号时整张 sheet 可滚动，不让 Column 溢出（任务书只给静态高度会翻车）。
      child: ConstrainedBox(
        constraints:
            BoxConstraints(maxHeight: MediaQuery.sizeOf(ctx).height * 0.85),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.info_outline, color: kPrimary, size: 18),
                  const SizedBox(width: 8),
                  Text('如何获取解锁码',
                      style: TextStyle(
                          color: kText,
                          fontSize: 16,
                          fontWeight: FontWeight.w600)),
                ],
              ),
              const SizedBox(height: 14),
              // 三步说明
              _stepRow(1, '微信加我', '搜微信号 $kWechatId，或截图去微信扫一扫'),
              const SizedBox(height: 10),
              _stepRow(
                  2, '转账 ¥$kEarlyBirdPrice', '备注「解锁码」，早鸟价前 $kEarlyBirdSeats 名'),
              const SizedBox(height: 10),
              _stepRow(3, '拿码激活', '我发你 20 位码，粘贴到 App 就好'),
              const SizedBox(height: 18),
              // 微信号复制区
              Container(
                width: double.infinity,
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                decoration: BoxDecoration(
                  color: kBg,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: kBorder),
                ),
                child: Row(
                  children: [
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('微信号',
                            style: TextStyle(color: kTextMuted, fontSize: 11)),
                        const SizedBox(height: 2),
                        Text(kWechatId,
                            style: TextStyle(
                                color: kText,
                                fontSize: 18,
                                fontWeight: FontWeight.w600,
                                letterSpacing: 0.5)),
                      ],
                    ),
                    const Spacer(),
                    TextButton.icon(
                      icon: Icon(_copied ? Icons.check : Icons.copy, size: 16),
                      label: Text(_copied ? '已复制' : '复制'),
                      style: TextButton.styleFrom(foregroundColor: kPrimary),
                      onPressed: () async {
                        await Clipboard.setData(
                            const ClipboardData(text: kWechatId));
                        if (!ctx.mounted) return;
                        // sheet 盖住了 SnackBar 的落点，可见反馈只能就地画：
                        // 按钮变「已复制」；SnackBar 留着给读屏播报（SnackBar 自带 live region）。
                        setState(() => _copied = true);
                        ScaffoldMessenger.of(ctx).showSnackBar(
                          const SnackBar(
                            content: Text('微信号已复制，去微信粘贴添加吧'),
                            duration: Duration(seconds: 2),
                          ),
                        );
                      },
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              // 底部小字
              Text(
                '白天一般 2 小时内回复 · 一个码绑一台设备 · 7 天不满意可退',
                style: TextStyle(color: kTextFaint, fontSize: 11),
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: kPrimary,
                    padding: const EdgeInsets.symmetric(vertical: 13),
                  ),
                  child: Text('我知道了',
                      style: TextStyle(color: kOnPrimary, fontSize: 15)),
                  onPressed: () => Navigator.pop(context),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 辅助：步骤行（任务书 §三）。
Widget _stepRow(int num, String title, String desc) {
  return Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Container(
        width: 22,
        height: 22,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: kPrimary.withValues(alpha: 0.12),
          shape: BoxShape.circle,
        ),
        child: Text('$num',
            style: TextStyle(
                color: kPrimary, fontSize: 12, fontWeight: FontWeight.w600)),
      ),
      const SizedBox(width: 10),
      // Expanded：长说明在窄屏必须能折行，否则 Row 里的非弹性 Column 会顶出边界。
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title,
                style: TextStyle(
                    color: kText, fontSize: 14, fontWeight: FontWeight.w500)),
            const SizedBox(height: 2),
            Text(desc, style: TextStyle(color: kTextMuted, fontSize: 12)),
          ],
        ),
      ),
    ],
  );
}
