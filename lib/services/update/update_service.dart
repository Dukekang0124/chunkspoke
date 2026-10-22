import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart'
    show MethodChannel, MissingPluginException, PlatformException;
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'version_compare.dart';
import 'sha256_util.dart';

/// 远端版本信息（对齐 version.json 规范）。
class VersionInfo {
  final String versionName;
  final int versionCode;
  final String url; // APK 主直链（HTTPS）
  final List<String> urls; // 主直链 + 备用源（可选；为空时只用 url）
  final String sha256;
  final int size; // 字节数
  final String notes;

  /// 可选：浏览器下载页（版本说明页/网盘页）。为空时浏览器下载回退到 [url]。
  /// 用于「App 内直连慢」的兜底：把地址交给系统浏览器，而不是自己拉 66MB。
  final String pageUrl;

  /// 可选：分片下载列表（jsDelivr/对象存储分块，单文件 ≤20MB 以绕开直连瓶颈）。
  /// 非空时优先走分片；全部失败再回退 [urls] 整包直链（字节相同可续传）。
  List<ApkPart> parts;

  VersionInfo({
    required this.versionName,
    required this.versionCode,
    required this.url,
    this.urls = const [],
    required this.sha256,
    required this.size,
    required this.notes,
    this.pageUrl = '',
    List<ApkPart> parts = const [],
  }) : parts = List<ApkPart>.of(parts);

  /// 交给浏览器打开的地址：优先下载页，其次 APK 直链。
  String get browserUrl => pageUrl.trim().isNotEmpty ? pageUrl.trim() : url;

  /// 依次尝试的下载地址（去空、去重、主直链永远排第一）。
  List<String> get downloadUrls {
    final list = buildDownloadUrls(<String?>[url, ...urls]);
    return list;
  }

  factory VersionInfo.fromJson(Map<String, dynamic> j) {
    final extra = <String?>[
      ...((j['urls'] as List?) ?? const []).map((e) => e?.toString()),
      (j['mirrorUrl'] ?? '').toString(),
    ];
    final all = buildDownloadUrls(<String?>[
      (j['url'] ?? j['apkUrl'] ?? '').toString(),
      ...extra,
    ]);
    return VersionInfo(
      versionName: (j['versionName'] ?? j['version'] ?? '0.0.0').toString(),
      versionCode: parseVersionCode(j['versionCode'] ?? j['buildNumber']),
      url: all.isEmpty ? '' : all.first,
      urls: all,
      sha256: (j['sha256'] ?? '').toString(),
      size: (j['size'] as int?) ?? 0,
      notes: (j['notes'] ?? '').toString(),
      pageUrl: (j['pageUrl'] ?? j['downloadPage'] ?? '').toString(),
      parts: ((j['parts'] as List?) ?? const [])
          .map(ApkPart.fromJson)
          .whereType<ApkPart>()
          .toList(),
    );
  }

  /// 把相对分片地址解析为绝对地址（基于清单所在目录）。
  void resolvePartUrls(String manifestUrl) {
    if (parts.isEmpty || manifestUrl.trim().isEmpty) return;
    final base = Uri.parse(manifestUrl);
    final resolved = parts.map((p) {
      if (p.url.startsWith('http://') || p.url.startsWith('https://')) return p;
      final u = Uri.parse(p.url);
      final abs = base.resolve(u.path.startsWith('/') ? u.path : u.path).toString();
      return ApkPart(abs, p.size);
    }).toList();
    parts
      ..clear()
      ..addAll(resolved);
  }
}

/// 分片下载描述（version.json 的可选 parts 字段，如 jsDelivr/对象存储分块）。
class ApkPart {
  final String url;
  final int size;
  const ApkPart(this.url, this.size);

  static ApkPart? fromJson(dynamic j) {
    if (j is! Map) return null;
    final url = (j['url'] ?? '').toString().trim();
    final size = (j['size'] as num?)?.toInt() ?? 0;
    if (url.isEmpty) return null;
    return ApkPart(url, size);
  }
}

/// 分片续传计划：从全局字节 [startAt] 起，还差哪些 (分片序号, 片内起始偏移)。
/// 分片按顺序拼接成完整文件，因此 .part 里已有的字节即全局前缀。
List<(int, int)> partPlan(List<int> sizes, int startAt) {
  final plan = <(int, int)>[];
  var offset = 0;
  for (var i = 0; i < sizes.length; i++) {
    final end = offset + sizes[i];
    if (startAt < end) {
      plan.add((i, startAt > offset ? startAt - offset : 0));
    }
    offset = end;
  }
  return plan;
}

/// 构造下载候选地址：跳过空串与重复项，保持顺序。
List<String> buildDownloadUrls(Iterable<String?> candidates) {
  final out = <String>[];
  for (final c in candidates) {
    final s = (c ?? '').trim();
    if (s.isEmpty || out.contains(s)) continue;
    out.add(s);
  }
  return out;
}

/// 检查结果状态：有新版 / 已是最新 / 检查失败（网络或未配置）。
enum CheckStatus { update, latest, error }

class CheckResult {
  final CheckStatus status;
  final VersionInfo info;
  const CheckResult(this.status, this.info);
}

/// 本地 APK 是否完整：期望大小未知(≤0)时只要非空即视为可用；否则要求字节数精确匹配。
bool sizeMatches(int actual, int expected) =>
    expected <= 0 ? actual > 0 : actual == expected;

/// 下载总字节数：优先用 version.json 的 size（与弹窗显示一致），
/// 缺失时才退回 Content-Length；206 续传时需叠加已下载起点。
int resolveDownloadTotal({
  required int expectedSize,
  required int contentLength,
  required int resumedBytes,
  required bool partial,
}) {
  if (expectedSize > 0) return expectedSize;
  final tail = contentLength > 0 ? contentLength : 0;
  return partial ? resumedBytes + tail : tail;
}

/// 服务器是否返回了网页/JSON 而非安装包（GitHub 404、CDN 错误页的典型形态）。
bool looksLikeHtmlPage(String? contentType) {
  final ct = (contentType ?? '').toLowerCase();
  return ct.contains('text/html') || ct.contains('application/json');
}

/// 断点标签：取目标包 SHA-256 前 8 位。断点文件按标签隔离，跨版本绝不互相续传
/// （上一版的残片拼进新版会得到「大小正好但 SHA 不符」的坏包，用户只能重下一次）。
String apkPartTag(String sha256) =>
    sha256.length >= 8 ? sha256.substring(0, 8) : '';

/// 断点文件名：无标签时沿用旧命名 `x.part`，有标签时 `x.<tag>.part`。
String apkPartName(String fileName, String tag) =>
    tag.isEmpty ? '$fileName.part' : '$fileName.$tag.part';

/// 目录内属于该包、但不属于当前标签的残片（含旧的无标签命名）。
List<String> staleApkParts(
  Iterable<String> entries,
  String fileName,
  String keepTag,
) {
  final keep = apkPartName(fileName, keepTag);
  final prefix = '$fileName.';
  final legacy = '$fileName.part';
  return [
    for (final e in entries)
      if (e != keep &&
          (e == legacy || (e.startsWith(prefix) && e.endsWith('.part'))))
        e,
  ];
}

/// 下载失败（携带可直接展示给用户的原因）。
class UpdateDownloadException implements Exception {
  final String message;
  const UpdateDownloadException(this.message);
  @override
  String toString() => 'UpdateDownloadException: $message';
}

String _brief(Object e) {
  final s = e.toString();
  return s.length > 80 ? '${s.substring(0, 80)}…' : s;
}

/// 可取消的下载句柄。
class DownloadHandle {
  final Future<String> future; // 完成时返回本地 APK 路径
  final void Function() cancel;
  DownloadHandle({required this.future, required this.cancel});
}

/// 应用内自更新服务（方案 v2.0 §9）：拉取 version.json → 数值比较 → 流式下载
/// （真实进度 + 可取消）→ SHA-256 校验 → 原生通道 FileProvider 调起安装。
/// 「更新源」为应用内**常量**（GitHub raw 直链），不经用户输入。
class UpdateService {
  /// 内置更新源：GitHub raw 直链（应用常量，用户不可见/不可改）。
  /// 可用 `--dart-define=CHUNKSPOKE_UPDATE_URL=...` 在构建期覆盖（调试/迁移用）。
  static const String defaultRemoteUrl = String.fromEnvironment(
    'CHUNKSPOKE_UPDATE_URL',
    defaultValue:
        'https://raw.githubusercontent.com/Dukekang0124/chunkspoke/main/version.json',
  );

  /// 远端清单候选源：按顺序尝试，任一可用即返回（避免单源失败直接「检查失败」）。
  /// - 官网同源副本：发版即生效，不受 jsDelivr tag 别名缓存滞后影响；
  /// - jsDelivr @latest：国内可达，但新 tag 的别名解析可能滞后，降为第二源；
  /// - raw：内容即时生效，但国内真机常不可达，仅作最后兜底。
  static const List<String> manifestUrls = <String>[
    'https://dukekang0124.github.io/chunkspoke/version.json',
    'https://cdn.jsdelivr.net/gh/Dukekang0124/chunkspoke@latest/version.json',
    defaultRemoteUrl,
    // 'https://<你的OSS或CDN域名>/chunkspoke/version.json', // 建议补充为第一优先级
  ];

  /// 下载落盘文件名（固定；供「本地已有完整包则直接安装」复用）。
  static const String apkFileName = 'chunkspoke_update.apk';
  static const MethodChannel _ch = MethodChannel('chunkspoke/update');

  /// version.json 单次请求超时（弱网下 6s 过短，易误报「检查失败」）。
  static const Duration checkTimeout = Duration(seconds: 10);

  /// 等响应头的超时：GitHub 直链先 302 再跳转对象存储，弱网/被墙时可能长时间无响应。
  static const Duration connectTimeout = Duration(seconds: 20);

  /// 无数据「停滞」超时：超过该时长没收到任何字节即判定卡死并给出可读提示，
  /// 避免下载弹窗永久停在 0%（这正是线上反馈的现象）。
  static const Duration idleTimeout = Duration(seconds: 25);

  /// 本机真实版本：取自 PackageInfo（避免被构建期 --build-number 覆盖、
  /// 也避免 assets/version.json 与安装包 versionCode 不一致导致误判）。
  Future<VersionInfo> local() async {
    final i = await PackageInfo.fromPlatform();
    return VersionInfo(
      versionName: i.version,
      versionCode: int.tryParse(i.buildNumber) ?? 0,
      url: '',
      sha256: '',
      size: 0,
      notes: '',
    );
  }

  /// 拉取远端 version.json 与本机版本比较，返回**三态**结果：
  ///  - update：有更高 versionCode（弹窗）；
  ///  - latest：等于或更低（toast 已是最新）；
  ///  - error：所有源均失败（网络/非 200/解析异常 → toast 检查失败）。
  ///
  /// 多源顺序尝试：raw 不通时自动切 jsDelivr 等备用源，避免单源故障直接「检查失败」。
  /// [client] 可注入（单测用 mock）；[current] 可注入本机版本（单测跳过 PackageInfo）。
  Future<CheckResult> check(
      {String? overrideUrl, http.Client? client, VersionInfo? current}) async {
    final cur = current ?? await local();
    final urls = (overrideUrl != null && overrideUrl.trim().isNotEmpty)
        ? <String>[overrideUrl.trim()]
        : manifestUrls;
    // 未配置（空）→ 明确归为失败，避免「假装已最新」。
    if (urls.isEmpty) return CheckResult(CheckStatus.error, cur);

    final created = client == null;
    client ??= http.Client();
    try {
      for (final url in urls) {
        // 单源重试 2 次：慢网首次握手慢很常见，直接换源可惜。
        for (var attempt = 0; attempt < 2; attempt++) {
          try {
            final r = await client.get(Uri.parse(url)).timeout(checkTimeout);
            if (r.statusCode != 200) {
              debugPrint('[update] $url → HTTP ${r.statusCode}，换源');
              break;
            }
            final decoded = jsonDecode(r.body);
            if (decoded is! Map<String, dynamic>) {
              debugPrint('[update] $url 清单格式异常，换源');
              break;
            }
            final latest = VersionInfo.fromJson(decoded);
            // 分片可能是相对路径：基于清单 URL 解析成绝对地址
            latest.resolvePartUrls(url);
            // 缺 versionCode 绝不能当成「已最新」→ 该源无效，换下一个。
            if (latest.versionCode <= 0) {
              debugPrint('[update] $url 缺少有效 versionCode，换源');
              break;
            }
            return isNewerVersion(cur.versionCode, latest.versionCode)
                ? CheckResult(CheckStatus.update, latest)
                : CheckResult(CheckStatus.latest, cur);
          } catch (e) {
            debugPrint('[update] $url 第 ${attempt + 1} 次失败：${_brief(e)}');
            // 两次都失败才换源
          }
        }
      }
      debugPrint('[update] 所有更新源均失败');
      return CheckResult(CheckStatus.error, cur);
    } finally {
      if (created) client.close();
    }
  }

  /// 本地已下载 APK 的路径。
  ///
  /// 必须落在 `getApplicationSupportDirectory()`（Android = `filesDir`），
  /// 因为 `res/xml/file_paths.xml` 只声明了 `files-path path="updates"`；
  /// 旧实现用 `getApplicationDocumentsDirectory()`（Android = `app_flutter`），
  /// FileProvider 找不到匹配根节点会抛 IllegalArgumentException，安装被静默吞掉。
  Future<String> apkPath() async {
    final dir = await getApplicationSupportDirectory();
    return '${dir.path}/updates/$apkFileName';
  }

  /// 历史落盘位置（v1.2.5 及以前）：仅用于升级后迁移缓存，避免重下整包。
  Future<String> legacyApkPath() async {
    final dir = await getApplicationDocumentsDirectory();
    return '${dir.path}/updates/$apkFileName';
  }

  /// 丢弃未完成的分段文件（含旧的无标签命名与全部标签变体）。
  /// 切换到备用下载源时必须调用：不同源的字节不能拼接，否则 SHA-256 必挂。
  Future<void> discardPartial(String fileName) async {
    try {
      final dir = await getApplicationSupportDirectory();
      for (final name in staleApkParts(_updateDirEntries(dir), fileName, '')) {
        await File('${dir.path}/updates/$name').delete();
      }
    } catch (_) {}
  }

  List<String> _updateDirEntries(Directory dir) {
    try {
      if (!dir.existsSync()) return const [];
      final sep = Platform.pathSeparator;
      return dir
          .listSync()
          .map((f) => f.path.split(sep).last)
          .toList(growable: false);
    } catch (_) {
      return const [];
    }
  }

  /// 清掉「别的版本」留下的残片：只保留本次标签对应的断点。
  Future<void> _dropStaleParts(String dirPath, String fileName, String keepTag) async {
    try {
      final dir = Directory('$dirPath/updates');
      for (final name in staleApkParts(_updateDirEntries(dir), fileName, keepTag)) {
        await File('${dir.path}/$name').delete();
        debugPrint('[update] 丢弃跨版本残片 $name（保留 ${apkPartName(fileName, keepTag)}）');
      }
    } catch (_) {}
  }

  /// 「本地已有完整包则复用」：若缓存 APK 存在、大小匹配且 SHA-256 校验通过，
  /// 直接返回其路径（安装界面取消后下次启动免重新下载）；否则返回 null。
  Future<String?> reusableCachedApk(VersionInfo info) async {
    final path = await apkPath();
    if (await _isCompleteApk(File(path), info)) return path;

    // 旧目录里的完整包：迁移到新目录（同一分区 rename，瞬时完成）。
    try {
      final legacy = File(await legacyApkPath());
      if (legacy.path != path && await _isCompleteApk(legacy, info)) {
        final target = File(path);
        await target.parent.create(recursive: true);
        if (await target.exists()) await target.delete();
        await legacy.rename(target.path);
        debugPrint('[update] 已迁移旧缓存 APK → ${target.path}');
        return target.path;
      }
    } catch (e) {
      debugPrint('[update] 迁移旧缓存失败：${_brief(e)}');
    }
    return null;
  }

  /// 文件是否为一个完整的可安装包（存在 + 大小匹配 + SHA-256 通过）。
  Future<bool> _isCompleteApk(File f, VersionInfo info) async {
    try {
      if (!await f.exists()) return false;
      if (!sizeMatches(await f.length(), info.size)) return false;
      if (info.sha256.isNotEmpty) {
        final actual = await fileSha256(f.path);
        if (!sha256Matches(actual, info.sha256)) {
          await f.delete(); // 损坏缓存：删除，待重下
          return false;
        }
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 流式下载 APK 到 `updates/`（FileProvider 可达），支持取消与断点续传。
  ///
  /// 与旧实现的关键差异（对应线上「0% 卡死」）：
  ///  1. 等响应头有 connectTimeout、无数据有 idleTimeout → 不再永久挂在 0%；
  ///  2. 校验状态码与 Content-Type → 404 网页不会被当成 APK 写盘；
  ///  3. 先写 `.part`，完成后 rename；中断/取消保留 `.part`，重试走 Range 续传；
  ///     断点按 [partTag]（目标包 SHA 前 8 位）隔离，跨版本残片直接丢弃；
  ///  4. 用 version.json 的 size 兜底总进度（服务端不给 Content-Length 时也能出进度）。
  DownloadHandle downloadApkCancellable(
    String url,
    String fileName,
    void Function(int received, int total) onProgress, {
    int expectedSize = 0,
    String partTag = '',
  }) {
    final client = http.Client();
    final completer = Completer<String>();
    StreamSubscription<List<int>>? sub;
    Timer? idleTimer;
    IOSink? sink;
    var stopped = false;

    void finishError(Object e) {
      idleTimer?.cancel();
      idleTimer = null;
      if (!completer.isCompleted) completer.completeError(e);
    }

    Future<void> start() async {
      try {
        final dir = await getApplicationSupportDirectory();
        final dest = File('${dir.path}/updates/$fileName');
        await _dropStaleParts(dir.path, fileName, partTag);
        final part = File(
            '${dir.path}/updates/${apkPartName(fileName, partTag)}');
        await dest.parent.create(recursive: true);
        if (stopped) return;

        var startAt = await part.exists() ? await part.length() : 0;
        if (expectedSize > 0 && startAt > expectedSize) {
          await part.delete(); // 分段比整包还大：已损坏，重下
          startAt = 0;
        }
        // 分段已完整（上次在 rename 前中断）：直接收尾，不发请求。
        if (expectedSize > 0 && startAt == expectedSize) {
          if (await dest.exists()) await dest.delete();
          await part.rename(dest.path);
          onProgress(startAt, expectedSize);
          if (!completer.isCompleted) completer.complete(dest.path);
          return;
        }

        final req = http.Request('GET', Uri.parse(url));
        // 必须显式 identity：部分 CDN/代理会对 APK 返回 gzip 分块流，
        // 断点续传拼出来的字节会变成半截压缩流（兄弟项目实测报 Filter error / SHA 必挂）。
        req.headers['accept-encoding'] = 'identity';
        if (startAt > 0) req.headers['range'] = 'bytes=$startAt-';

        http.StreamedResponse resp;
        try {
          resp = await client.send(req).timeout(connectTimeout);
        } on TimeoutException {
          throw const UpdateDownloadException('连接更新服务器超时，请检查网络后重试');
        } on SocketException catch (e) {
          throw UpdateDownloadException(
              '无法连接更新服务器（${e.osError?.message ?? '网络不可达'}）');
        } on http.ClientException catch (e) {
          throw UpdateDownloadException('下载请求失败：${e.message}');
        }
        if (stopped) return;

        final code = resp.statusCode;
        debugPrint('[update] GET $url → $code '
            'len=${resp.contentLength} ct=${resp.headers['content-type']}');
        if (startAt > 0 && code == 416) {
          await part.delete();
          throw const UpdateDownloadException('续传位置已失效，请重新下载');
        }
        if (code != 200 && code != 206) {
          throw UpdateDownloadException(code == 404
              ? '更新包不存在（服务器 404），请检查发布地址'
              : '服务器返回 $code，无法下载更新包');
        }
        if (looksLikeHtmlPage(resp.headers['content-type'])) {
          throw const UpdateDownloadException('下载地址返回的是网页，不是安装包');
        }

        final partial = code == 206 && startAt > 0;
        final base = partial ? startAt : 0;
        var total = resolveDownloadTotal(
          expectedSize: expectedSize,
          contentLength: resp.contentLength ?? 0,
          resumedBytes: base,
          partial: partial,
        );
        // version.json 的 size 可能与线上 APK 短暂不一致：以服务端实际长度为准，
        // 否则会把一个完整包误判成「下载不完整」。
        final serverTotal = partial
            ? base + (resp.contentLength ?? 0)
            : (resp.contentLength ?? 0);
        if (serverTotal > 0 && total > 0 && serverTotal != total) {
          debugPrint('[update] size 不一致（json=$total / 服务端=$serverTotal），以服务端为准');
          total = serverTotal;
        }

        sink = part.openWrite(mode: partial ? FileMode.append : FileMode.write);
        var received = base;
        onProgress(received, total);

        // 停滞判定采用「两段式」：休眠/切后台会让 Dart 计时器整体冻结，
        // 恢复瞬间计时器往往先于数据到达触发（荣耀 MagicOS 等系统会冻结后台进程），
        // 直接判失败会误杀正常下载；因此第一次超时只重新计时，连续两轮无数据才报错。
        var idleStrikes = 0;
        void armIdle() {
          idleTimer?.cancel();
          idleTimer = Timer(idleTimeout, () {
            idleStrikes++;
            if (idleStrikes < 2) {
              armIdle();
              return;
            }
            stopped = true;
            sub?.cancel();
            client.close();
            sink?.close().catchError((_) {});
            finishError(
                const UpdateDownloadException('下载停滞：长时间收不到数据，请检查网络后重试'));
          });
        }

        armIdle();
        sub = resp.stream.listen(
          (chunk) {
            sink?.add(chunk);
            received += chunk.length;
            idleStrikes = 0; // 收到数据即清空停滞计数
            armIdle();
            onProgress(received, total);
          },
          onDone: () async {
            idleTimer?.cancel();
            if (stopped) return;
            stopped = true;
            try {
              await sink?.close();
              if (total > 0 && received < total) {
                throw UpdateDownloadException(
                    '下载不完整（${received ~/ 1024}KB / ${total ~/ 1024}KB），已保留进度，重试可续传');
              }
              if (await dest.exists()) await dest.delete();
              await part.rename(dest.path);
              if (!completer.isCompleted) completer.complete(dest.path);
            } catch (e) {
              finishError(e is UpdateDownloadException
                  ? e
                  : UpdateDownloadException('写入安装包失败：${_brief(e)}'));
            }
          },
          onError: (Object e, StackTrace st) async {
            idleTimer?.cancel();
            stopped = true;
            try {
              await sink?.close();
            } catch (_) {}
            finishError(UpdateDownloadException('下载中断：${_brief(e)}'));
          },
          cancelOnError: true,
        );
      } catch (e) {
        try {
          await sink?.close();
        } catch (_) {}
        finishError(e is UpdateDownloadException
            ? e
            : UpdateDownloadException('下载失败：${_brief(e)}'));
      }
    }

    start(); // 触发下载（fire-and-forget，结果经 completer 传递）
    return DownloadHandle(
      future: completer.future,
      cancel: () {
        if (stopped) return;
        stopped = true;
        idleTimer?.cancel();
        sub?.cancel();
        client.close();
        try {
          sink?.close();
        } catch (_) {}
        if (!completer.isCompleted) {
          completer.completeError(const UpdateCancelledException());
        }
      },
    );
  }

  /// 分片下载：按顺序拉取 [parts] 拼到同一 .part（已有字节 = 完整文件前缀），
  /// 支持全局断点续传与取消；分片与整包直链是同一文件，因此分片失败换直链**无需重下**。
  DownloadHandle downloadApkPartsCancellable(
    List<ApkPart> parts,
    String fileName,
    void Function(int received, int total) onProgress, {
    int expectedSize = 0,
    String partTag = '',
  }) {
    final client = http.Client();
    final completer = Completer<String>();
    var stopped = false;
    IOSink? sink;
    Timer? idleTimer;
    var idleStrikes = 0;

    void finishError(Object e) {
      idleTimer?.cancel();
      idleTimer = null;
      if (!completer.isCompleted) completer.completeError(e);
    }

    void armIdle() {
      idleTimer?.cancel();
      idleTimer = Timer(idleTimeout, () {
        idleStrikes++;
        if (idleStrikes < 2) {
          armIdle();
          return;
        }
        stopped = true;
        client.close(); // 打断在途流，run() 的 catch 会收尾
        finishError(const UpdateDownloadException('下载停滞：长时间收不到数据，请检查网络后重试'));
      });
    }

    Future<void> run() async {
      try {
        final dir = await getApplicationSupportDirectory();
        final dest = File('${dir.path}/updates/$fileName');
        await _dropStaleParts(dir.path, fileName, partTag);
        final part = File(
            '${dir.path}/updates/${apkPartName(fileName, partTag)}');
        await dest.parent.create(recursive: true);
        if (stopped) return;

        var startAt = await part.exists() ? await part.length() : 0;
        if (expectedSize > 0 && startAt > expectedSize) {
          await part.delete(); // 分段比整包还大：已损坏，重下
          startAt = 0;
        }
        final total = expectedSize > 0
            ? expectedSize
            : parts.fold<int>(0, (a, p) => a + p.size);
        if (expectedSize > 0 && startAt == expectedSize) {
          if (await dest.exists()) await dest.delete();
          await part.rename(dest.path);
          onProgress(startAt, total);
          if (!completer.isCompleted) completer.complete(dest.path);
          return;
        }

        sink = part.openWrite(mode: FileMode.append);
        var received = startAt;
        onProgress(received, total);
        armIdle();

        for (final (idx, inStart)
            in partPlan(parts.map((p) => p.size).toList(), startAt)) {
          if (stopped) return;
          final p = parts[idx];
          final req = http.Request('GET', Uri.parse(p.url));
          req.headers['accept-encoding'] = 'identity';
          if (inStart > 0) req.headers['range'] = 'bytes=$inStart-';

          http.StreamedResponse resp;
          try {
            resp = await client.send(req).timeout(connectTimeout);
          } on TimeoutException {
            throw const UpdateDownloadException('连接更新服务器超时，请检查网络后重试');
          } on SocketException catch (e) {
            throw UpdateDownloadException(
                '无法连接更新服务器（${e.osError?.message ?? '网络不可达'}）');
          } on http.ClientException catch (e) {
            throw UpdateDownloadException('下载请求失败：${e.message}');
          }
          if (stopped) return;
          if (resp.statusCode != 200 && resp.statusCode != 206) {
            throw UpdateDownloadException(
                '分片下载失败（HTTP ${resp.statusCode}）');
          }
          if (looksLikeHtmlPage(resp.headers['content-type'])) {
            throw const UpdateDownloadException('分片地址返回的是网页，不是安装包');
          }

          // 服务器不支持 Range（200 整片返回）时，跳过片内已有字节
          var skip = (resp.statusCode == 200 && inStart > 0) ? inStart : 0;
          await for (final chunk in resp.stream) {
            if (stopped) return;
            idleStrikes = 0;
            armIdle();
            if (skip > 0) {
              if (chunk.length <= skip) {
                skip -= chunk.length;
                continue;
              }
              final rest = chunk.sublist(skip);
              skip = 0;
              sink?.add(rest);
              received += rest.length;
              onProgress(received, total);
              continue;
            }
            sink?.add(chunk);
            received += chunk.length;
            onProgress(received, total);
          }
          if (stopped) return;
        }

        idleTimer?.cancel();
        await sink?.close();
        sink = null;
        if (expectedSize > 0 && received < expectedSize) {
          throw UpdateDownloadException(
              '下载不完整（${received ~/ 1024}KB / ${expectedSize ~/ 1024}KB），已保留进度，重试可续传');
        }
        if (await dest.exists()) await dest.delete();
        await part.rename(dest.path);
        if (!completer.isCompleted) completer.complete(dest.path);
      } catch (e) {
        try {
          await sink?.close();
        } catch (_) {}
        if (stopped) return; // 取消/停滞路径：completer 已完成
        finishError(e is UpdateDownloadException
            ? e
            : UpdateDownloadException('下载失败：${_brief(e)}'));
      }
    }

    run();
    return DownloadHandle(
      future: completer.future,
      cancel: () {
        if (stopped) return;
        stopped = true;
        idleTimer?.cancel();
        client.close();
        sink?.close().catchError((_) {});
        if (!completer.isCompleted) {
          completer.completeError(const UpdateCancelledException());
        }
      },
    );
  }

  Future<String> downloadApk(String url, String fileName,
          void Function(int received, int total) onProgress,
          {int expectedSize = 0}) =>
      downloadApkCancellable(url, fileName, onProgress,
              expectedSize: expectedSize)
          .future;

  /// SHA-256 校验：不匹配则删除损坏文件并返回 false（绝不安装损坏包）。
  Future<bool> verifySha256(String path, String expected) async {
    if (expected.isEmpty) return true;
    try {
      final actual = await fileSha256(path);
      if (sha256Matches(actual, expected)) return true;
    } catch (_) {
      return false;
    }
    try {
      await File(path).delete();
    } catch (_) {}
    return false;
  }

  Future<bool> canInstallPackages() async {
    try {
      return await _ch.invokeMethod('canInstallPackages') ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<void> openInstallSettings() async {
    try {
      await _ch.invokeMethod('openInstallSettings');
    } catch (_) {}
  }

  /// 用系统浏览器打开下载地址（不自己下 66MB）。
  /// 国内直连 GitHub 慢，但浏览器可续传、可后台、能转给下载工具，成功率高于 App 内单线程。
  Future<void> openInBrowser(String url) async {
    final target = url.trim();
    if (target.isEmpty) {
      throw const UpdateDownloadException('没有可用的下载地址，请联系开发者');
    }
    try {
      await _ch.invokeMethod('openUrl', target);
    } on PlatformException catch (e) {
      throw UpdateDownloadException('无法打开浏览器（${e.message ?? e.code}）');
    } on MissingPluginException {
      throw UpdateDownloadException('当前版本不支持跳转浏览器，请手动访问：$target');
    }
  }

  /// 调起系统安装界面。失败不再静默：抛出 [UpdateDownloadException]，
  /// 让上层能提示「无法调起安装」，而不是点了没反应。
  Future<void> installApk(String path) async {
    if (!await File(path).exists()) {
      throw const UpdateDownloadException('安装包不存在，请重新下载');
    }
    try {
      await _ch.invokeMethod('installApk', path);
    } on PlatformException catch (e) {
      debugPrint('[update] installApk 失败：${e.code} ${e.message}');
      throw UpdateDownloadException('无法调起系统安装（${e.message ?? e.code}）');
    } on MissingPluginException {
      throw const UpdateDownloadException('安装通道不可用，请手动安装');
    }
  }
}
