import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

/// The browser hands back a blob URL. Fetching it is how the bytes come
/// out, and revoking it afterwards is how the blob is released — without
/// that, every voice note recorded in a session stays in memory until
/// the tab is closed.
Future<Uint8List?> readRecording(String location) async {
  if (location.isEmpty) return null;
  final response = await web.window.fetch(location.toJS).toDart;
  final buffer = await response.arrayBuffer().toDart;
  final bytes = buffer.toDart.asUint8List();
  web.URL.revokeObjectURL(location);
  return bytes;
}
