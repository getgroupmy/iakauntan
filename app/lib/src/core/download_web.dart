import 'dart:js_interop';

import 'package:web/web.dart' as web;

/// Hands the text to the browser as a download.
///
/// A `data:` URI would be shorter, but Chrome refuses top-level navigation
/// to one, so this goes through a blob and a detached anchor. The object
/// URL is revoked straight after the click; the download has already been
/// handed off by then.
Future<bool> saveTextFile(String filename, String mimeType, String text) async {
  final blob = web.Blob(
    <JSAny>[text.toJS].toJS,
    web.BlobPropertyBag(type: '$mimeType;charset=utf-8'),
  );
  final url = web.URL.createObjectURL(blob);
  final anchor = web.document.createElement('a') as web.HTMLAnchorElement
    ..href = url
    ..download = filename;
  anchor.click();
  web.URL.revokeObjectURL(url);
  return true;
}
