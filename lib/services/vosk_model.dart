import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import 'update/sha256_util.dart';

/// 模型进度阶段。
enum ModelPhase { downloading, extracting }

/// 模型下载/解压进度事件。
/// - downloading 阶段：0.5% 节流，每次携带实时速度与剩余时间；
/// - 自动修复时 [message] 非空（UI 显示「语音包下载损坏，正在自动重新下载」）；
/// - extracting 阶段：仅发一次（received=total）。
class ModelProgress {
  final ModelPhase phase;
  final int received;
  final int total;
  final double bytesPerSecond;
  final Duration? remaining;
  final String? message;
  const ModelProgress({
    required this.phase,
    required this.received,
    required this.total,
    this.bytesPerSecond = 0,
    this.remaining,
    this.message,
  });
}

/// 模型分块描述（version.json model.parts 的一项）。
class ModelPart {
  final String url;
  final int size;

  /// 分块 SHA-256（小写十六进制）。为空时退化为仅校验长度。
  final String sha256;

  /// 备用分块源（raw / Pages 等），jsDelivr 各边缘节点失败后依次切换。
  final List<String> fallbacks;

  const ModelPart(
    this.url,
    this.size, {
    this.sha256 = '',
    this.fallbacks = const [],
  });

  bool get hasHash => RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(sha256);

  static ModelPart? fromJson(dynamic j) {
    if (j is! Map) return null;
    final url = (j['url'] ?? '').toString().trim();
    final size = (j['size'] as num?)?.toInt() ?? 0;
    if (url.isEmpty || size <= 0) return null;
    final fallbacks = <String>{
      ...((j['fallbacks'] as List?) ?? const [])
          .map((e) => e.toString().trim()),
      (j['rawUrl'] ?? '').toString().trim(),
    }.where((e) => e.isNotEmpty).toList();
    return ModelPart(
      url,
      size,
      sha256: (j['sha256'] ?? '').toString().trim(),
      fallbacks: fallbacks,
    );
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

  /// 分块长度之和必须等于整包长度，否则续传/拼接的全局偏移没有意义。
  bool get isValid {
    if (name.isEmpty || modelVersion.isEmpty || size <= 0 || parts.isEmpty) {
      return false;
    }
    final sum = parts.fold<int>(0, (a, p) => a + p.size);
    return sum == size;
  }
}

/// 模型下载/校验/解压失败（可携带可读原因）。
class ModelDownloadException implements Exception {
  final String message;
  const ModelDownloadException(this.message);
  @override
  String toString() => 'ModelDownloadException: $message';
}

/// 分块源不可用（HTTP 4xx / Range 起点不符）：换源，不整块作废。
class _SourceMiss implements Exception {
  final String message;
  const _SourceMiss(this.message);
  @override
  String toString() => message;
}

/// 服务端正常结束但长度不符：该块内容不可信，整块作废重下。
class _ShortBlock implements Exception {
  final String message;
  const _ShortBlock(this.message);
  @override
  String toString() => message;
}

String _brief(Object e) {
  final s = e.toString();
  return s.length > 80 ? '${s.substring(0, 80)}…' : s;
}

/// 磁盘写满：Linux/Android ENOSPC=28，Windows ERROR_DISK_FULL=112。
bool _isNoSpace(Object e) {
  if (e is! FileSystemException) return false;
  final err = e.osError;
  if (err != null && (err.errorCode == 28 || err.errorCode == 112)) return true;
  return e.message.toLowerCase().contains('no space');
}

/// 模型 zip 的分块下载、SHA-256 校验、解压落盘与 model.json 元数据。
///
/// B3 加固：
/// - 每个分块独立落盘为 `<name>.zip.partN`，完成后立即校验分块 SHA-256；
/// - 续传起点只认「该分块已落盘字节数」，禁止按全局 .part 长度盲 append；
/// - 长度不符/哈希不符 → 整个分块作废重下；
/// - jsDelivr 四个边缘域名都失败后切 raw/Pages 备用分块源；
/// - 下载/校验失败自动重试 2 轮，仍失败才交给用户手动重试。
/// 全部依赖可注入（client / 落盘目录），宿主单测无需真实网络与原生 libvosk。
class ModelManager {
  ModelManager({
    required this.manifest,
    http.Client? client,
    Future<Directory> Function()? baseDir,
    Duration retryDelay = const Duration(milliseconds: 400),
    Duration connectTimeout = const Duration(seconds: 20),
    int autoRetryRounds = 2,
  })  : _client = client ?? http.Client(),
        _baseDir = baseDir,
        _retryDelay = retryDelay,
        _connectTimeout = connectTimeout,
        _autoRetryRounds = autoRetryRounds;

  final ModelManifest manifest;
  final http.Client _client;
  final Future<Directory> Function()? _baseDir;
  final Duration _retryDelay;
  final Duration _connectTimeout;
  final int _autoRetryRounds;

  final StreamController<ModelProgress> _progress =
      StreamController<ModelProgress>.broadcast();
  Stream<ModelProgress> get progress => _progress.stream;

  Stopwatch _roundClock = Stopwatch();
  int _lastEmitted = 0;
  int _progressStep = 1;

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

  /// 确保模型就绪：短路 → 分块下载（块级校验）→ 拼接 → 整包 SHA → 解压 → 写 model.json。
  /// 下载/校验失败自动重试 [_autoRetryRounds] 轮，全部失败才抛用户可读异常。
  Future<String> ensureModel() async {
    if (!manifest.isValid) {
      throw const ModelDownloadException('语音包清单异常，请更新应用后重试');
    }
    if (await isReady()) return (await _modelDir()).path;

    final dir = await _modelsDir();
    await dir.create(recursive: true);
    final zip = File(path.join(dir.path, '${manifest.name}.zip'));

    ModelDownloadException? lastError;
    for (var round = 0; round <= _autoRetryRounds; round++) {
      if (round > 0) {
        debugPrint('[model] 第 $round 轮自动修复：清理临时包后重新下载');
        _lastEmitted = 0;
        _progress.add(ModelProgress(
          phase: ModelPhase.downloading,
          received: 0,
          total: manifest.size,
          message: '语音包下载损坏，正在自动重新下载',
        ));
        await Future<void>.delayed(_retryDelay * (round * 2));
      }
      try {
        await _downloadVerifiedZip(zip);
        lastError = null;
        break;
      } on ModelDownloadException catch (e) {
        lastError = e;
        debugPrint('[model] 第 ${round + 1} 轮失败：${e.message}');
        await _deleteQuietly(zip);
      } catch (e) {
        lastError = ModelDownloadException(_isNoSpace(e)
            ? '设备存储空间不足，请清理后重试'
            : '语音包下载失败，请检查网络后重试');
        debugPrint('[model] 第 ${round + 1} 轮异常：$e');
        await _deleteQuietly(zip);
      }
    }
    if (lastError != null) throw lastError;

    // 整包 SHA 已通过，才开始解压，绝不使用损坏模型。
    final modelDir = await _modelDir();
    if (await modelDir.exists()) await modelDir.delete(recursive: true);

    try {
      _progress.add(ModelProgress(
          phase: ModelPhase.extracting,
          received: manifest.size,
          total: manifest.size));
      // 流式解压：高清发音包含 63MB 模型，整包 decodeBytes 会同时驻留
      // zip 与解压内容（>120MB），低端机有 OOM 风险。
      await extractFileToDisk(zip.path, dir.path);
    } catch (e) {
      try {
        await modelDir.delete(recursive: true);
      } catch (_) {}
      throw ModelDownloadException(_isNoSpace(e)
          ? '设备存储空间不足，请清理后重试'
          : '语音包解压失败，请重试');
    }

    // 写 model.json（modelVersion + sha256），随后删除 zip（短路只认解压目录）。
    final meta = await _metaFile();
    await meta.writeAsString(jsonEncode({
      'modelVersion': manifest.modelVersion,
      'sha256': manifest.sha256,
    }));
    try {
      await zip.delete();
    } catch (_) {}

    if (!await modelDir.exists()) {
      throw const ModelDownloadException('语音包解压失败，请重试');
    }
    return modelDir.path;
  }

  /// 分块下载 → 逐块校验 → 拼接 → 整包 SHA-256。
  Future<void> _downloadVerifiedZip(File zip) async {
    final dir = zip.parent;
    final blocks = <File>[
      for (var i = 0; i < manifest.parts.length; i++)
        File(path.join(dir.path, '${manifest.name}.zip.part$i')),
    ];
    await _deleteQuietly(zip);
    await _deleteQuietly(File('${zip.path}.assembling'));
    // 旧版是单一 <name>.zip.part 全局偏移续传，语义与分块独立落盘不兼容，直接清理。
    await _deleteQuietly(File('${zip.path}.part'));

    _roundClock = Stopwatch()..start();
    _lastEmitted = 0;
    _progressStep = (manifest.size * 0.005).round().clamp(1, 1 << 30);

    var usedMirror = false;
    try {
      await _ensureBlocks(blocks);
    } on ModelDownloadException {
      if (manifest.mirrorUrl.isEmpty) rethrow;
      debugPrint('[model] 分块双源均失败，切整包兜底源');
      await _downloadWhole(zip);
      usedMirror = true;
    }

    if (!usedMirror) await _assemble(zip, blocks);

    final length = await _fileLength(zip);
    final actual = await fileSha256(zip.path);
    debugPrint(
        '[model] 拼接完成 length=$length/${manifest.size} sha256=$actual 期望=${manifest.sha256}');
    if (length != manifest.size || !sha256Matches(actual, manifest.sha256)) {
      await _deleteQuietly(zip);
      await _deleteBlocks(blocks);
      throw const ModelDownloadException('语音包下载损坏，请重试');
    }
    await _deleteBlocks(blocks);
    await _deleteQuietly(File('${zip.path}.whole.part'));
  }

  /// 顺序确保每个分块完整且哈希正确；已校验的分块直接复用。
  Future<void> _ensureBlocks(List<File> blocks) async {
    var done = 0;
    for (var i = 0; i < manifest.parts.length; i++) {
      final part = manifest.parts[i];
      final file = blocks[i];
      var len = await _fileLength(file);
      if (len > part.size) {
        debugPrint('[model] 分块 $i 超出预期长度（$len/${part.size}），整块作废');
        await _deleteQuietly(file);
        len = 0;
      }
      if (len == part.size) {
        if (await _blockValid(file, part)) {
          done += part.size;
          _lastEmitted = done;
          _emit(done);
          continue;
        }
        debugPrint('[model] 分块 $i 已落盘但哈希不符，整块作废');
        await _deleteQuietly(file);
        len = 0;
      }
      _lastEmitted = done;
      await _downloadBlock(i, part, file, len, done);
      done += part.size;
      _lastEmitted = done;
      _emit(done);
    }
  }

  /// 下载单个分块：源不可用换源；长度/哈希不符整块作废；网络中断按落盘偏移续传。
  Future<void> _downloadBlock(int index, ModelPart part, File file,
      int startAt, int completedBefore) async {
    final sources = _sourcesFor(part);
    if (sources.isEmpty) {
      throw const ModelDownloadException('语音包下载地址缺失，请更新应用后重试');
    }
    var resumeAt = startAt;
    for (var attempt = 0; attempt < sources.length; attempt++) {
      final url = sources[attempt];
      if (resumeAt >= part.size) {
        if (await _blockValid(file, part)) return;
        await _deleteQuietly(file);
        resumeAt = 0;
      }
      try {
        await _fetch(url, file, resumeAt, part.size, completedBefore);
        if (part.hasHash && !await _blockValid(file, part)) {
          debugPrint('[model] 分块 $index 哈希不符，整块重下（第 ${attempt + 1} 次）');
          await _deleteQuietly(file);
          resumeAt = 0;
          if (attempt < sources.length - 1) {
            await Future<void>.delayed(_retryDelay * (attempt + 1));
          }
          continue;
        }
        return;
      } on _SourceMiss catch (e) {
        debugPrint('[model] 分块 $index 源不可用（$url）：$e');
      } on _ShortBlock catch (e) {
        debugPrint('[model] 分块 $index 长度不符（$url）：$e，整块作废重下');
        await _deleteQuietly(file);
        resumeAt = 0;
      } catch (e) {
        if (_isNoSpace(e)) {
          debugPrint('[model] 分块 $index 写入失败：磁盘空间不足');
          await _deleteQuietly(file);
          throw const ModelDownloadException('设备存储空间不足，请清理后重试');
        }
        // 网络中断：只认已落盘字节数，下一源从这里对齐续传，绝不盲 append。
        resumeAt = await _fileLength(file);
        debugPrint(
            '[model] 分块 $index 中断（$url），已落盘 $resumeAt/${part.size}，按落盘偏移续传');
        if (resumeAt >= part.size) {
          if (!part.hasHash || await _blockValid(file, part)) return;
          await _deleteQuietly(file);
          resumeAt = 0;
        }
      }
      if (attempt < sources.length - 1) {
        await Future<void>.delayed(_retryDelay * (attempt + 1));
      }
    }
    throw const ModelDownloadException('语音包下载失败，请检查网络后重试');
  }

  /// 当前分块的候选源：jsDelivr 四边缘域名 → 备用分块源（raw / Pages）。
  List<String> _sourcesFor(ModelPart part) {
    final out = <String>[];
    final u = Uri.tryParse(part.url);
    if (u != null && u.host.endsWith('jsdelivr.net')) {
      for (final host in _cdnHosts) {
        final url = u.replace(host: host).toString();
        if (!out.contains(url)) out.add(url);
      }
    } else if (part.url.isNotEmpty) {
      out.add(part.url);
    }
    for (final fallback in part.fallbacks) {
      if (fallback.isNotEmpty && !out.contains(fallback)) out.add(fallback);
    }
    return out;
  }

  /// 把一个源写入分块文件。偏移以磁盘实际长度为准；成功后长度必须精确匹配。
  Future<void> _fetch(
      String url, File file, int startAt, int expectedSize, int completedBefore) async {
    var from = await _fileLength(file);
    if (from > expectedSize) {
      await _deleteQuietly(file);
      from = 0;
    }
    if (from != startAt) {
      debugPrint('[model] 续传偏移对齐：调用方 $startAt → 落盘 $from');
    }
    if (from == expectedSize) return;

    final sink = file.openWrite(mode: FileMode.append);
    var written = from;
    try {
      final req = http.Request('GET', Uri.parse(url));
      req.headers['accept-encoding'] = 'identity';
      if (from > 0) req.headers['range'] = 'bytes=$from-';
      final resp = await _client.send(req).timeout(_connectTimeout);
      if (resp.statusCode != 200 && resp.statusCode != 206) {
        throw _SourceMiss('HTTP ${resp.statusCode}');
      }
      if (resp.statusCode == 206) {
        final range = resp.headers['content-range'];
        final m = range == null
            ? null
            : RegExp(r'bytes\s+(\d+)-').firstMatch(range);
        if (m != null && int.parse(m.group(1)!) != from) {
          throw _SourceMiss('Content-Range 起点 ${m.group(1)} ≠ $from');
        }
      }
      // 服务器忽略 Range（200 整块返回）时，本地跳过已落盘前缀。
      var skip = (resp.statusCode == 200 && from > 0) ? from : 0;
      await for (final chunk in resp.stream) {
        List<int> data = chunk;
        if (skip > 0) {
          if (chunk.length <= skip) {
            skip -= chunk.length;
            continue;
          }
          data = chunk.sublist(skip);
          skip = 0;
        }
        sink.add(data);
        written += data.length;
        if (written > expectedSize) {
          throw _ShortBlock('分块超出预期长度（$written/$expectedSize）');
        }
        final global = completedBefore + written;
        if (global - _lastEmitted >= _progressStep) {
          _lastEmitted = global;
          _emit(global);
        }
      }
    } finally {
      await sink.close();
    }
    final disk = await _fileLength(file);
    if (disk != expectedSize) {
      throw _ShortBlock('分块长度不符（$disk/$expectedSize）');
    }
  }

  /// 整包兜底下载（mirrorUrl，单段续传，最终仍走整包 SHA 校验）。
  Future<void> _downloadWhole(File zip) async {
    final part = File('${zip.path}.whole.part');
    var startAt = await _fileLength(part);
    if (startAt > manifest.size) {
      await _deleteQuietly(part);
      startAt = 0;
    }
    _roundClock = Stopwatch()..start();
    _lastEmitted = startAt;
    try {
      await _fetch(manifest.mirrorUrl, part, startAt, manifest.size, 0);
    } on ModelDownloadException {
      rethrow;
    } on _SourceMiss catch (e) {
      throw ModelDownloadException('语音包下载失败（${_brief(e)}），请检查网络后重试');
    } on _ShortBlock catch (e) {
      throw ModelDownloadException('语音包下载失败（${_brief(e)}），请检查网络后重试');
    } catch (e) {
      throw ModelDownloadException(_friendlyNetError(e));
    }
    final actual = await fileSha256(part.path);
    if (!sha256Matches(actual, manifest.sha256)) {
      await _deleteQuietly(part);
      throw const ModelDownloadException('语音包下载损坏，请重试');
    }
    if (await zip.exists()) await zip.delete();
    await part.rename(zip.path);
  }

  Future<void> _assemble(File zip, List<File> blocks) async {
    final tmp = File('${zip.path}.assembling');
    await _deleteQuietly(tmp);
    final sink = tmp.openWrite();
    try {
      for (var i = 0; i < blocks.length; i++) {
        final len = await _fileLength(blocks[i]);
        if (len != manifest.parts[i].size) {
          throw ModelDownloadException('语音包分块缺失（$i：$len/${manifest.parts[i].size}）');
        }
        await sink.addStream(blocks[i].openRead());
      }
    } catch (e) {
      try {
        await sink.close();
      } catch (_) {}
      await _deleteQuietly(tmp);
      rethrow;
    }
    await sink.close();
    if (await zip.exists()) await zip.delete();
    await tmp.rename(zip.path);
  }

  Future<bool> _blockValid(File file, ModelPart part) async {
    if (await _fileLength(file) != part.size) return false;
    if (!part.hasHash) return true;
    try {
      final actual = await fileSha256(file.path);
      return sha256Matches(actual, part.sha256);
    } catch (_) {
      return false;
    }
  }

  void _emit(int received) {
    final ms = _roundClock.elapsedMilliseconds;
    final speed = ms > 0 ? received * 1000.0 / ms : 0.0;
    final remaining = speed > 0
        ? Duration(
            milliseconds:
                ((manifest.size - received) * 1000 / speed).round())
        : null;
    _progress.add(ModelProgress(
      phase: ModelPhase.downloading,
      received: received,
      total: manifest.size,
      bytesPerSecond: speed,
      remaining: remaining,
    ));
  }

  Future<int> _fileLength(File f) async {
    try {
      return await f.exists() ? await f.length() : 0;
    } catch (_) {
      return 0;
    }
  }

  Future<void> _deleteQuietly(File f) async {
    try {
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }

  Future<void> _deleteBlocks(List<File> blocks) async {
    for (final f in blocks) {
      await _deleteQuietly(f);
    }
  }

  /// jsDelivr 多 CDN 域名：国内不同运营商/地区可达性差异大，逐域名重试。
  static const List<String> _cdnHosts = [
    'cdn.jsdelivr.net',
    'fastly.jsdelivr.net',
    'gcore.jsdelivr.net',
    'testingcf.jsdelivr.net',
  ];

  /// 把底层网络异常转成用户可读文案（避免 SocketException 原样弹到 UI）。
  static String _friendlyNetError(Object e) {
    if (_isNoSpace(e)) return '设备存储空间不足，请清理后重试';
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
    return '语音包下载失败，请检查网络后重试';
  }

  /// 手动「重试」入口：删除全部未完成分块、拼接临时文件与未就绪模型目录。
  Future<void> resetIncomplete() async {
    try {
      final dir = await _modelDir();
      if (await dir.exists() && !await isReady()) {
        await dir.delete(recursive: true);
      }
      await _clearStaging();
    } catch (_) {}
  }

  Future<void> _clearStaging() async {
    final dir = await _modelsDir();
    if (!await dir.exists()) return;
    final prefix = '${manifest.name}.zip';
    await for (final entity in dir.list(followLinks: false)) {
      if (entity is! File) continue;
      final name = path.basename(entity.path);
      if (name == prefix || name.startsWith('$prefix.')) {
        await _deleteQuietly(entity);
      }
    }
  }

  /// 丢弃本地模型（目录 + zip + 全部分块临时文件），回到「缺失」态。
  Future<void> discard() async {
    try {
      final dir = await _modelDir();
      if (await dir.exists()) await dir.delete(recursive: true);
      await _clearStaging();
    } catch (_) {
      // 清理尽力而为，失败不抛。
    }
  }

  void dispose() {
    _progress.close();
    _client.close();
  }
}
