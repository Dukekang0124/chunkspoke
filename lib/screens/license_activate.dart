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
              style: TextStyle(
                  color: kText, fontSize: 16, letterSpacing: 1.2),
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
                    style: TextStyle(
                        color: kTextFaint, fontSize: 12)),
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
                onPressed: _busy || lic == null || _controller.text.trim().isEmpty
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
                  color: kTextSecondary,
                  fontSize: 12,
                  fontFamily: 'monospace'),
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

/// 墙点 sheet：G 关灰锁 / 口语日记入口共用，只说明、不拦截、不弹窗骚扰。
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
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
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
            const SizedBox(height: 10),
            Text(detail,
                style: TextStyle(color: kTextSecondary, fontSize: 13)),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: kPrimary),
                onPressed: () {
                  Navigator.pop(ctx);
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (_) => const LicenseActivateScreen()),
                  );
                },
                child: Text('输入解锁码',
                    style: TextStyle(color: kOnPrimary)),
              ),
            ),
            const SizedBox(height: 8),
            Center(
              child: TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text('先继续学生存 S0 + A–F',
                    style: TextStyle(color: kTextMuted)),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
