import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'download_diag.dart';

/// 用户主动取消（与失败区分：取消不弹错误页、不记失败）。
class DownloadCancelled implements Exception {
  const DownloadCancelled();
  @override
  String toString() => 'DownloadCancelled';
}

/// 该源不可用（HTTP 4xx/5xx、返回网页、Content-Range 起点不符、416 且本地长度既非零也不是全长）。
/// 调用方应换源；换源前必须按落盘长度重新对齐（本文件已处理 416 的删档）。
class SourceMiss implements Exception {
  final String message;
  final int http;
  const SourceMiss(this.message, {this.http = 0});
  @override
  String toString() => 'SourceMiss: $message';
}

/// 服务端正常结束但字节数不符：该次内容不可信，调用方应作废文件重下。
class ShortRead implements Exception {
  final String message;
  const ShortRead(this.message);
  @override
  String toString() => 'ShortRead: $message';
}

/// 一次单源抓取的结果。
class SegmentResult {
  /// 抓取结束后该文件在本地的字节数。
  final int bytes;

  /// 是否已达到预期总长（expectedSize ≤ 0 时恒为 true，因为无法判断）。
  final bool reachedExpected;

  const SegmentResult(this.bytes, this.reachedExpected);
}

/// 取消令牌：APK 下载需要「取消按钮」，模型下载不需要。
class DownloadCancelToken {
  bool cancelled = false;
  void cancel() => cancelled = true;
}

/// 单源流式抓取（同一套逻辑给 APK 与应用内语音模型/语音包共用）。
///
/// 关键约定（1.5.8.1 热修）：
///  1. **显式 `Accept-Encoding: identity`**：APK/模型是二进制，拿到 gzip 分块流再拼接
///     会得到半截压缩数据（sha 必挂、Range 语义错乱）。
///  2. **Content-Length 缺失容忍**：jsDelivr 边缘偶发不给长度；此时以 [expectedSize]
///     （来自清单）为准，清单也没有就以「流结束」为准，不因缺头直接失败。
///  3. **416 特判**：本地长度 == 预期总长 → 直接返回「已完成」，交给调用方做 sha 校验；
///     否则删档从零重发一次（同源），再失败才换源。**绝不带着可疑残片续传**。
///  4. 续传只发生在「网络中断」这一条路径上：起点永远取磁盘真实长度，不盲信调用方。
///  5. 停滞两段式判定：连续两轮无数据才判失败（休眠/切后台会冻结计时器）。
///
/// 返回前不保证 sha 正确——校验由调用方做（APK 整包 sha / 模型分块 sha）。
Future<SegmentResult> fetchSegment({
  required http.Client client,
  required String url,
  required File file,
  required int expectedSize,
  int remoteBase = 0,
  DownloadDiag? diag,
  String diagPhase = '下载',
  DownloadCancelToken? cancelToken,
  void Function(int received, int total)? onProgress,
  Duration connectTimeout = const Duration(seconds: 20),
  Duration idleTimeout = const Duration(seconds: 25),
}) async {
  void checkCancel() {
    if (cancelToken?.cancelled == true) throw const DownloadCancelled();
  }

  var from = await _length(file);
  if (expectedSize > 0 && from > expectedSize) {
    // 比整包还大：已经不可能拼出正确内容。
    diag?.add(
        phase: diagPhase,
        source: url,
        expected: expectedSize,
        actual: from,
        note: '本地残片超出预期长度，删档从零');
    await _deleteQuietly(file);
    from = 0;
  }
  if (expectedSize > 0 && from == expectedSize) {
    return SegmentResult(from, true);
  }

  for (var attempt = 0; attempt < 2; attempt++) {
    checkCancel();
    // 本地文件可能是「多个分片拼成的一个文件」：[remoteBase] 是该分片在其中的起点，
    // Range 必须按片内偏移发，不能用全局长度。
    final remoteFrom = from - remoteBase;
    final req = http.Request('GET', Uri.parse(url));
    req.headers['accept-encoding'] = 'identity';
    if (remoteFrom > 0) req.headers['range'] = 'bytes=$remoteFrom-';

    http.StreamedResponse resp;
    try {
      resp = await client.send(req).timeout(connectTimeout);
    } on TimeoutException {
      diag?.add(phase: diagPhase, source: url, expected: expectedSize, actual: from, note: '连接超时');
      throw const SourceMiss('连接超时', http: 0);
    } on SocketException catch (e) {
      diag?.add(
          phase: diagPhase,
          source: url,
          expected: expectedSize,
          actual: from,
          note: '网络不可达（${e.osError?.message ?? 'socket'}）');
      throw SourceMiss('网络不可达（${e.osError?.message ?? 'socket'}）');
    } on http.ClientException catch (e) {
      diag?.add(
          phase: diagPhase,
          source: url,
          expected: expectedSize,
          actual: from,
          note: '请求失败（${e.message}）');
      throw SourceMiss('请求失败（${e.message}）');
    }

    final code = resp.statusCode;
    final cl = resp.contentLength;

    // —— 416 特判（热修核心）——
    if (code == 416) {
      final localLen = await _length(file);
      if (expectedSize > 0 && localLen == expectedSize) {
        diag?.add(
            phase: diagPhase,
            source: url,
            http: 416,
            expected: expectedSize,
            actual: localLen,
            note: '服务器 416，但本地已是全长为，直接进校验');
        return SegmentResult(localLen, true);
      }
      diag?.add(
          phase: diagPhase,
          source: url,
          http: 416,
          expected: expectedSize,
          actual: localLen,
          note: '服务器 416，本地 $localLen 非全长，删档从零重试');
      await _deleteQuietly(file);
      from = 0;
      continue; // 同源从零重发一次
    }

    if (code != 200 && code != 206) {
      diag?.add(
          phase: diagPhase,
          source: url,
          http: code,
          expected: expectedSize,
          actual: from,
          note: 'HTTP 异常，换源');
      throw SourceMiss('HTTP $code', http: code);
    }

    final ct = (resp.headers['content-type'] ?? '').toLowerCase();
    if (ct.contains('text/html') || ct.contains('application/json')) {
      diag?.add(
          phase: diagPhase,
          source: url,
          http: code,
          note: '返回网页/JSON 而非二进制（$ct），换源');
      throw SourceMiss('返回的是网页而非文件', http: code);
    }

    if (code == 206) {
      final m = RegExp(r'bytes\s+(\d+)-').firstMatch(resp.headers['content-range'] ?? '');
      if (m != null && int.parse(m.group(1)!) != remoteFrom) {
        diag?.add(
            phase: diagPhase,
            source: url,
            http: code,
            expected: expectedSize,
            actual: from,
            note: 'Content-Range 起点 ${m.group(1)} ≠ 期望 $remoteFrom，换源');
        throw SourceMiss('Content-Range 起点不符', http: code);
      }
    }

    // 总长：清单优先；其次服务端给出的长度（206 需叠加起点）；都缺则 0（进度退化为已下字节）
    final serverTotal = remoteBase > 0
        ? 0
        : (code == 206 ? from + (cl ?? 0) : (cl ?? 0));
    var total = expectedSize > 0 ? expectedSize : serverTotal;
    if (expectedSize > 0 && serverTotal > 0 && serverTotal != expectedSize) {
      diag?.add(
          phase: diagPhase,
          source: url,
          http: code,
          expected: expectedSize,
          actual: serverTotal,
          note: '清单长度与服务器不一致，以服务器为准');
      total = serverTotal;
    }

    // 服务器忽略 Range（200 整片返回）：跳过已落盘前缀，避免重复写。
    var skip = (code == 200 && remoteFrom > 0) ? remoteFrom : 0;
    if (skip > 0) {
      diag?.add(
          phase: diagPhase,
          source: url,
          http: code,
          expected: expectedSize,
          actual: from,
          note: '服务器忽略 Range，本地跳过已有前缀');
    }

    final sink = file.openWrite(mode: FileMode.append);
    var written = from;
    var idleStrikes = 0;
    Timer? idle;
    StreamSubscription<List<int>>? sub;
    final done = Completer<void>();
    void abort(Object e) {
      if (done.isCompleted) return;
      done.completeError(e);
    }

    void armIdle() {
      idle?.cancel();
      idle = Timer(idleTimeout, () {
        idleStrikes++;
        if (idleStrikes < 2) {
          armIdle();
          return;
        }
        // 只取消本条流的订阅，不关共享 client（模型下载后面还要用同一个 client）。
        sub?.cancel();
        abort(const SourceMiss('下载停滞（长时间收不到数据）'));
      });
    }

    onProgress?.call(written, total);
    armIdle();
    sub = resp.stream.listen(
      (chunk) {
        try {
          checkCancel();
          List<int> data = chunk;
          if (skip > 0) {
            if (chunk.length <= skip) {
              skip -= chunk.length;
              return;
            }
            data = chunk.sublist(skip);
            skip = 0;
          }
          sink.add(data);
          written += data.length;
          idleStrikes = 0;
          armIdle();
          if (expectedSize > 0 && written > expectedSize) {
            throw ShortRead('超出预期长度（$written/$expectedSize）');
          }
          onProgress?.call(written, total);
        } catch (e) {
          sub?.cancel();
          abort(e);
        }
      },
      onError: (Object e, StackTrace st) => abort(e),
      onDone: () {
        idle?.cancel();
        if (!done.isCompleted) done.complete();
      },
      cancelOnError: true,
    );

    try {
      await done.future;
    } on DownloadCancelled {
      rethrow;
    } on ShortRead {
      rethrow;
    } on SourceMiss catch (e) {
      diag?.add(
          phase: diagPhase,
          source: url,
          http: code,
          expected: expectedSize,
          actual: written,
          note: e.message);
      rethrow;
    } catch (e) {
      if (cancelToken?.cancelled == true) throw const DownloadCancelled();
      // 磁盘写满等本地 IO 错误原样上抛：由调用方翻译成「存储空间不足」，不要伪装成网络失败。
      if (e is FileSystemException) {
        diag?.add(
            phase: diagPhase,
            source: url,
            http: code,
            expected: expectedSize,
            actual: written,
            note: '写入失败（${_brief(e)}）');
        rethrow;
      }
      diag?.add(
          phase: diagPhase,
          source: url,
          http: code,
          expected: expectedSize,
          actual: written,
          note: '传输中断（${_brief(e)}）');
      throw SourceMiss('传输中断（${_brief(e)}）', http: code);
    } finally {
      idle?.cancel();
      await sub.cancel();
      try {
        await sink.close();
      } catch (_) {}
    }

    final disk = await _length(file);
    if (expectedSize > 0 && disk != expectedSize) {
      diag?.add(
          phase: diagPhase,
          source: url,
          http: code,
          expected: expectedSize,
          actual: disk,
          note: '长度不符，保留已落盘字节待续传');
      throw ShortRead('长度不符（$disk/$expectedSize）');
    }
    return SegmentResult(disk, expectedSize <= 0 || disk == expectedSize);
  }

  // 两次都走到 416 分支（从零仍 416）：该源不可信。
  throw const SourceMiss('HTTP 416（删档重试后仍失败）', http: 416);
}

String _brief(Object e) {
  final s = e.toString();
  return s.length > 80 ? '${s.substring(0, 80)}…' : s;
}

Future<int> _length(File f) async {
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
