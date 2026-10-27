import 'dart:async';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

/// 导出：把文本作为下载文件交给浏览器（Blob + 临时 a[download]）。
Future<void> saveTextFile(String name, String content) async {
  final blob = web.Blob(
    <JSAny>[content.toJS].toJS,
    web.BlobPropertyBag(type: 'application/json;charset=utf-8'),
  );
  final url = web.URL.createObjectURL(blob);
  final a = web.HTMLAnchorElement()
    ..href = url
    ..download = name
    ..style.display = 'none';
  web.document.body?.appendChild(a);
  a.click();
  a.remove();
  web.URL.revokeObjectURL(url);
}

/// 导入：弹系统文件选择框，读回文本；用户取消返回 null。
Future<String?> pickTextFile() {
  final completer = Completer<String?>();
  final input = web.HTMLInputElement()
    ..type = 'file'
    ..accept = '.json,application/json'
    ..style.display = 'none';
  web.document.body?.appendChild(input);

  var settled = false;
  late final JSFunction onFocus;

  void finish(String? value) {
    if (settled) return;
    settled = true;
    web.window.removeEventListener('focus', onFocus);
    input.remove();
    if (!completer.isCompleted) completer.complete(value);
  }

  onFocus = ((web.Event _) {
    // 取消选择不会触发 change；焦点回来后若仍无文件，视为取消。
    Future<void>.delayed(const Duration(milliseconds: 500), () {
      if (!settled && (input.files == null || input.files!.length == 0)) finish(null);
    });
  }).toJS;
  web.window.addEventListener('focus', onFocus);

  input.onchange = ((web.Event _) {
    final files = input.files;
    if (files == null || files.length == 0) {
      finish(null);
      return;
    }
    final file = files.item(0);
    if (file == null) {
      finish(null);
      return;
    }
    final reader = web.FileReader();
    reader.onload = ((web.Event _) {
      final value = reader.result?.dartify();
      finish(value is String ? value : null);
    }).toJS;
    reader.onerror = ((web.Event _) => finish(null)).toJS;
    reader.readAsText(file);
  }).toJS;

  input.click();
  return completer.future;
}
