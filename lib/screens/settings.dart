import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/loaders.dart';
import '../services/update_service.dart';
import '../ui/theme.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> with WidgetsBindingObserver {
  late final TextEditingController _key;
  late final TextEditingController _region;
  late final TextEditingController _updateUrl;
  bool _checking = false;
  String _ver = '1.0.0';
  String? _pendingInstallPath;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final p = Provider.of<ProgressService>(context, listen: false);
    _key = TextEditingController(text: p.azureKey ?? '');
    _region = TextEditingController(text: p.azureRegion ?? '');
    _updateUrl = TextEditingController(text: p.updateUrl ?? '');
    UpdateService().local().then((v) => setState(() => _ver = v.version));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _key.dispose();
    _region.dispose();
    _updateUrl.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 从系统“安装未知应用”设置返回后，若已获权限则自动重新触发安装。
    if (state == AppLifecycleState.resumed && _pendingInstallPath != null) {
      _resumeInstall();
    }
  }

  Future<void> _resumeInstall() async {
    final up = UpdateService();
    if (await up.canInstallPackages()) {
      final path = _pendingInstallPath;
      _pendingInstallPath = null;
      await up.installApk(path!);
    }
  }

  void _save() {
    final p = Provider.of<ProgressService>(context, listen: false);
    final k = _key.text.trim();
    final r = _region.text.trim();
    final u = _updateUrl.text.trim();
    p.setAzureKey(k.isEmpty ? null : k);
    p.setAzureRegion(r.isEmpty ? null : r);
    p.setUpdateUrl(u.isEmpty ? null : u);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Saved.'), duration: Duration(seconds: 1)),
    );
  }

  Future<void> _checkUpdate() async {
    final p = Provider.of<ProgressService>(context, listen: false);
    setState(() => _checking = true);
    final up = UpdateService();
    final (has, info) = await up.check(p.updateUrl);
    if (!mounted) return;
    setState(() => _checking = false);
    if (!has || info.apkUrl.isEmpty) {
      if (!mounted) return;
      showDialog(
        context: context,
        builder: (_) => AlertDialog(
          backgroundColor: const Color(0xFF1A1A2E),
          title: const Text('Up to date', style: TextStyle(color: Colors.white)),
          content: Text('You have the latest version (${info.version}).',
              style: const TextStyle(color: Colors.white70)),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('OK', style: TextStyle(color: Colors.white70)),
            ),
          ],
        ),
      );
      return;
    }
    _startDownload(up, info);
  }

  void _startDownload(UpdateService up, VersionInfo info) {
    final prog = ValueNotifier<double>(0);
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A2E),
        title: const Text('Downloading update', style: TextStyle(color: Colors.white)),
        content: ValueListenableBuilder<double>(
          valueListenable: prog,
          builder: (_, v, __) => Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              LinearProgressIndicator(value: v, color: kPrimary),
              const SizedBox(height: 10),
              Text('${(v * 100).round()}%',
                  style: const TextStyle(color: Colors.white70)),
            ],
          ),
        ),
      ),
    );
    up
        .downloadApk(info.apkUrl, 'chunkspoke_update.apk', (r, t) {
          if (t > 0) prog.value = r / t;
        })
        .then((path) async {
          if (mounted && Navigator.of(context).canPop()) Navigator.of(context).pop();
          if (await up.canInstallPackages()) {
            await up.installApk(path);
          } else {
            // 无权限 → 自定义深色弹窗引导去设置，返回后自动重触发
            _pendingInstallPath = path;
            if (!mounted) return;
            showDialog(
              context: context,
              builder: (_) => AlertDialog(
                backgroundColor: const Color(0xFF1A1A2E),
                title: const Text('Permission needed', style: TextStyle(color: Colors.white)),
                content: const Text(
                  'To install the update, allow "Install unknown apps" for ChunkSpoke, then come back.',
                  style: TextStyle(color: Colors.white70),
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Later', style: TextStyle(color: Colors.white38)),
                  ),
                  TextButton(
                    onPressed: () {
                      Navigator.pop(context);
                      up.openInstallSettings();
                    },
                    child: const Text('Go to Settings', style: TextStyle(color: kPrimary)),
                  ),
                ],
              ),
            );
          }
        })
        .catchError((e) {
          if (mounted && Navigator.of(context).canPop()) Navigator.of(context).pop();
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Download failed: $e')),
          );
        });
  }

  Widget _label(String t) =>
      Text(t, style: const TextStyle(color: Colors.white70, fontSize: 14));

  InputDecoration _dec(String hint) => InputDecoration(
        hintText: hint,
        hintStyle: const TextStyle(color: Colors.white38),
        filled: true,
        fillColor: const Color(0xFF1A1A2E),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
      );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _label('Azure Speech Key'),
            const SizedBox(height: 8),
            TextField(
              controller: _key,
              obscureText: true,
              style: const TextStyle(color: Colors.white),
              decoration: _dec('Paste your key (optional)'),
            ),
            const SizedBox(height: 12),
            _label('Azure Region'),
            const SizedBox(height: 8),
            TextField(
              controller: _region,
              style: const TextStyle(color: Colors.white),
              decoration: _dec('e.g. eastasia (optional)'),
            ),

            const SizedBox(height: 20),
            const Divider(color: Colors.white12),
            _label('更新源 version.json URL'),
            const SizedBox(height: 8),
            TextField(
              controller: _updateUrl,
              style: const TextStyle(color: Colors.white, fontSize: 13),
              decoration: _dec('https://raw.githubusercontent.com/.../version.json'),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: kPrimary),
                onPressed: _save,
                child: const Text('Save', style: TextStyle(color: Colors.white)),
              ),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton(
                onPressed: _checking ? null : _checkUpdate,
                child: _checking
                    ? const Text('Checking…', style: TextStyle(color: Colors.white54))
                    : const Text('Check for update', style: TextStyle(color: Colors.white70)),
              ),
            ),
            const SizedBox(height: 24),
            Center(
              child: Text('ChunkSpoke v$_ver',
                  style: const TextStyle(color: Colors.white38)),
            ),
          ],
        ),
      ),
    );
  }
}
