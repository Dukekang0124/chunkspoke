import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import 'update/sha256_util.dart';
import 'update/update_service.dart' show partPlan;

/// 模型进度阶段。
enum ModelPhase { downloading, extracting }

/// 模型下载/解压进度事件。
/// - downloading 阶段：0.5% 节流，每次携带实时速度与剩余时间；
/// - extracting 阶段：仅发一次（received=total）。
class ModelProgress {
  final ModelPhase phase;
  final int received;
  final int total;
  final double bytesPerSecond;
  final Duration? remaining;
  const ModelProgress({
    required this.phase,
    required this.received,
    required this.total,
    this.bytesPerSecond = 0,
    this.remaining,
  });
}

/// 模型分块描述（version.json model.parts 的一项）。
class ModelPart {
  final String url;
  final int size;
  const ModelPart(this.url, this.size);

  static ModelPart? fromJson(dynamic j) {
    if (j is! Map) return null;
    final url = (j['url'] ?? '').toString().trim();
    final size = (j['size'] as num?)?.toInt() ?? 0;
    if (url.isEmpty || size <= 0) return null;
    return ModelPart(url, size);
  }
}

/// 离线语音模型清单（version.json 的 model 段）。app 首启据此下载/校验/解压。
class ModelManifest {
  final String name;
  final String modelVersion;
  final String sha256; // 完整 zip 的 SHA-256（小写十六进制）
  final int size;
  final List<ModelPart> parts;
  final String mirrorUrl; // 分块全失败时的整包兜底源（可选，空则不分流）

  const ModelManifest({
    required this.name,
    required this.modelVersion,
    required this.sha256,
    required this.size,
    required this.parts,
    this.mirrorUrl = '',
  });

  factory ModelManifest.fromJson(dynamic j) {
    if (j is! Map) throw const FormatException('model 段不是对象');
    final parts = ((j['parts'] as List?) ?? const [])
        .map(ModelPart.fromJson)
        .whereType<ModelPart>()
        .toList();
    return ModelManifest(
      name: (j['name'] ?? '').toString().trim(),
      modelVersion: (j['modelVersion'] ?? '').toString().trim(),
      sha256: (j['sha256'] ?? '').toString().trim(),
      size: (j['size'] as num?)?.toInt() ?? 0,
      parts: parts,
      mirrorUrl: (j['mirrorUrl'] ?? '').toString().trim(),
    );
  }

  bool get isValid =>
      name.isNotEmpty && modelVersion.isNotEmpty && size > 0 && parts.isNotEmpty;
}

/// 模型下载/校验/解压失败（可携带可读原因）。
class ModelDownloadException implements Exception {
  final String message;
  const ModelDownloadException(this.message);
  @override
  String toString() => 'ModelDownloadException: $message';
}

String _brief(Object e) {
  final s = e.toString();
  return s.length > 80 ? '${s.substring(0, 80)}…' : s;
}

/// 模型 zip 的分块下载、SHA-256 校验、解压落盘与 model.json 元数据。
/// 全部依赖可注入（client / 落盘目录），宿主单测无需真实网络与原生 libvosk。
class ModelManager {
  ModelManager({
    required this.manifest,
    http.Client? client,
    Future<Directory> Function()? baseDir,
  })  : _client = client ?? http.Client(),
        _baseDir = baseDir;

  final ModelManifest manifest;
  final http.Client _client;
  final Future<Directory> Function()? _baseDir;

  final StreamController<ModelProgress> _progress =
      StreamController<ModelProgress>.broadcast();
  Stream<ModelProgress> get progress => _progress.stream;

  /// 模型根目录（默认 <documents>/models；测试注入临时目录）。
  Future<Directory> _modelsDir() async {
    if (_baseDir != null) return _baseDir();
    final docs = await getApplicationDocumentsDirectory();
    return Directory(path.join(docs.path, 'models'));
  }

  Future<Directory> _modelDir() async {
    final base = await _modelsDir();
    return Directory(path.join(base.path, manifest.name));
  }

  Future<String> modelDirPath() async => (await _modelDir()).path;

  Future<File> _metaFile() async {
    final dir = await _modelDir();
    return File(path.join(dir.path, 'model.json'));
  }

  /// 短路判断：模型目录存在，且 model.json 的 modelVersion 与清单一致。
  Future<bool> isReady() async {
    try {
      final dir = await _modelDir();
      if (!await dir.exists()) return false;
      final meta = await _metaFile();
      if (!await meta.exists()) return false;
      final j = jsonDecode(await meta.readAsString()) as Map<String, dynamic>;
      return (j['modelVersion'] ?? '').toString() == manifest.modelVersion;
    } catch (_) {
      return false;
    }
  }

  /// 确保模型就绪：短路 → 分块下载 → SHA-256 校验 → 解压 → 写 model.json。
  /// 返回模型目录绝对路径。
  Future<String> ensureModel() async {
    if (!manifest.isValid) {
      throw const ModelDownloadException('模型清单无效（缺 name/版本/分块/大小）');
    }
    if (await isReady()) return (await _modelDir()).path;

    final dir = await _modelsDir();
    await dir.create(recursive: true);
    final zip = File(path.join(dir.path, '${manifest.name}.zip'));

    // 分块优先；全失败切整包兜底源（切源）。
    try {
      await _downloadParts(zip);
    } on ModelDownloadException {
      if (manifest.mirrorUrl.isEmpty) rethrow;
      debugPrint('[model] 分块下载失败，切整包兜底源');
      await _downloadWhole(zip);
    }

    // SHA-256 校验（失败即删包，绝不使用损坏模型）。
    final actual = await fileSha256(zip.path);
    if (!sha256Matches(actual, manifest.sha256)) {
      try {
        await zip.delete();
      } catch (_) {}
      throw const ModelDownloadException('模型校验失败（SHA-256 不匹配）');
    }

    // 解压前清掉版本不匹配的旧目录，避免半解压残留。
    final modelDir = await _modelDir();
    if (await modelDir.exists()) await modelDir.delete(recursive: true);

    try {
      _progress.add(ModelProgress(
          phase: ModelPhase.extracting,
          received: manifest.size,
          total: manifest.size));
      final archive = ZipDecoder().decodeBytes(await zip.readAsBytes());
      await extractArchiveToDisk(archive, dir.path);
    } catch (e) {
      try {
        await modelDir.delete(recursive: true);
      } catch (_) {}
      throw ModelDownloadException('模型解压失败：${_brief(e)}');
    }

    // 写 model.json（modelVersion + sha256），随后删除 zip（硬化①：短路只认解压目录）。
    final meta = await _metaFile();
    await meta.writeAsString(jsonEncode({
      'modelVersion': manifest.modelVersion,
      'sha256': manifest.sha256,
    }));
    try {
      await zip.delete();
    } catch (_) {}

    if (!await modelDir.exists()) {
      throw const ModelDownloadException('模型解压目录缺失');
    }
    return modelDir.path;
  }

  /// 分块下载（复用 partPlan 续传计划）。
  Future<void> _downloadParts(File zip) async {
    final part = File('${zip.path}.part');
    var startAt = await part.exists() ? await part.length() : 0;
    if (startAt > manifest.size) {
      await part.delete();
      startAt = 0;
    }
    if (startAt == manifest.size) {
      if (await zip.exists()) await zip.delete();
      await part.rename(zip.path);
      return;
    }
    final segments = partPlan(
            manifest.parts.map((p) => p.size).toList(), startAt)
        .map((e) => (manifest.parts[e.$1].url, e.$2))
        .toList();
    await _download(zip, segments, startAt);
  }

  /// 整包兜底下载（mirrorUrl，单段续传）。
  Future<void> _downloadWhole(File zip) async {
    final part = File('${zip.path}.part');
    var startAt = await part.exists() ? await part.length() : 0;
    if (startAt > manifest.size) {
      await part.delete();
      startAt = 0;
    }
    if (startAt == manifest.size) {
      if (await zip.exists()) await zip.delete();
      await part.rename(zip.path);
      return;
    }
    await _download(zip, [(manifest.mirrorUrl, startAt)], startAt);
  }

  /// jsDelivr 多 CDN 域名：国内不同运营商/地区可达性差异大，逐域名重试。
  static const List<String> _cdnHosts = [
    'cdn.jsdelivr.net',
    'fastly.jsdelivr.net',
    'gcore.jsdelivr.net',
    'testingcf.jsdelivr.net',
  ];

  /// 单段最多尝试次数（走完一轮镜像域名再重来一轮）。
  static const int _maxSegmentAttempts = 8;

  /// 把 jsDelivr URL 换成指定镜像域名；非 jsDelivr 源原样返回。
  static String _mirrorUrl(String url, int attempt) {
    final u = Uri.tryParse(url);
    if (u == null || !u.host.endsWith('jsdelivr.net')) return url;
    return u.replace(host: _cdnHosts[attempt % _cdnHosts.length]).toString();
  }

  /// 把底层网络异常转成用户可读文案（避免 SocketException 原样弹到 UI）。
  static String _friendlyNetError(Object e) {
    final s = e.toString();
    if (s.contains('Connection reset') || s.contains('Connection refused')) {
      return '网络连接被中断，请检查网络后重试';
    }
    if (s.contains('SocketException') || s.contains('ClientException')) {
      return '无法连接下载服务器，请检查网络后重试';
    }
    if (s.contains('TimeoutException') || s.contains('timeout')) {
      return '下载超时，请检查网络后重试';
    }
    return _brief(e);
  }

  /// 顺序下载若干 (url, 片内起始偏移) 片段，append 到 <zip>.part，全程 0.5% 节流报进度。
  /// 加固：每段失败自动换 jsDelivr 镜像域名 + Range 断点续传重试（最多 8 次），
  /// 把「Connection reset by peer」这类单次抖动挡在下载层，不直接弹给用户。
  Future<void> _download(
      File zip, List<(String, int)> segments, int startAt) async {
    final part = File('${zip.path}.part');
    final total = manifest.size;
    final sink = part.openWrite(mode: FileMode.append);
    var received = startAt;
    final stopwatch = Stopwatch()..start();
    var lastEmitted = startAt;
    final step = (total * 0.005).round().clamp(1, 1 << 30);

    void emit() {
      final ms = stopwatch.elapsedMilliseconds;
      final speed = ms > 0 ? received * 1000.0 / ms : 0.0;
      final remaining = speed > 0
          ? Duration(milliseconds: ((total - received) * 1000 / speed).round())
          : null;
      _progress.add(ModelProgress(
        phase: ModelPhase.downloading,
        received: received,
        total: total,
        bytesPerSecond: speed,
        remaining: remaining,
      ));
    }

    try {
      emit();
      for (final (rawUrl, segStart) in segments) {
        var written = 0; // 本段已写入字节数（失败后据此 Range 续传）
        var attempt = 0;
        while (true) {
          final url = _mirrorUrl(rawUrl, attempt);
          final reqStart = segStart + written;
          try {
            final req = http.Request('GET', Uri.parse(url));
            req.headers['accept-encoding'] = 'identity';
            if (reqStart > 0) req.headers['range'] = 'bytes=$reqStart-';
            final resp = await _client
                .send(req)
                .timeout(const Duration(seconds: 20));
            if (resp.statusCode != 200 && resp.statusCode != 206) {
              if (resp.statusCode >= 500) {
                // 5xx 多为 CDN 抖动，值得换域名重试。
                throw Exception('HTTP ${resp.statusCode}');
              }
              // 4xx（404 等）换域名也无济于事，直接给出明确原因。
              throw ModelDownloadException('下载失败（HTTP ${resp.statusCode}）');
            }
            var skip = (resp.statusCode == 200 && reqStart > 0) ? reqStart : 0;
            await for (final chunk in resp.stream) {
              if (skip > 0) {
                if (chunk.length <= skip) {
                  skip -= chunk.length;
                  continue;
                }
                final rest = chunk.sublist(skip);
                skip = 0;
                sink.add(rest);
                received += rest.length;
                written += rest.length;
              } else {
                sink.add(chunk);
                received += chunk.length;
                written += chunk.length;
              }
              if (received - lastEmitted >= step) {
                lastEmitted = received;
                emit();
              }
            }
            break; // 本段完成
          } on ModelDownloadException {
            rethrow; // 业务异常（HTTP 4xx 等）不重试
          } catch (e) {
            attempt++;
            if (attempt >= _maxSegmentAttempts) {
              throw ModelDownloadException(_friendlyNetError(e));
            }
            // 已写入字节保留，换镜像域名后从断点 Range 续传。
            await Future<void>.delayed(Duration(milliseconds: 400 * attempt));
          }
        }
      }
      await sink.close();
      if (received < total) {
        throw ModelDownloadException('模型下载不完整（$received/$total）');
      }
      if (await zip.exists()) await zip.delete();
      await part.rename(zip.path);
      emit();
    } catch (e) {
      await sink.close().catchError((_) {});
      rethrow;
    }
  }

  /// 丢弃本地模型（目录 + zip + 残留分片），回到「缺失」态供全量重下（硬化④）。
  Future<void> discard() async {
    try {
      final base = await _modelsDir();
      final dir = await _modelDir();
      if (await dir.exists()) await dir.delete(recursive: true);
      final zip = File(path.join(base.path, '${manifest.name}.zip'));
      if (await zip.exists()) await zip.delete();
      final part = File('${zip.path}.part');
      if (await part.exists()) await part.delete();
    } catch (_) {
      // 清理尽力而为，失败不抛。
    }
  }

  void dispose() {
    _progress.close();
    _client.close();
  }
}
