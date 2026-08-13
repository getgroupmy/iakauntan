import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform;
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:path_provider/path_provider.dart';

/// Android and iOS only. `dart.library.io` is also true on macOS,
/// Windows and Linux, where the plugin exists as a Dart API with no
/// native side behind it — calling it there is a MissingPluginException
/// rather than a compile error, which is exactly the sort of failure
/// worth ruling out before it happens.
bool get onDeviceReaderAvailable =>
    defaultTargetPlatform == TargetPlatform.android ||
    defaultTargetPlatform == TargetPlatform.iOS;

/// The printing on one image, as ML Kit reads it.
///
/// Latin script: Malaysian receipts are printed in Malay and English,
/// both of which it covers. A Chinese-language receipt from a shop in
/// Penang would want the Chinese recognizer, which is a second model and
/// a second download — worth adding when somebody asks, not before.
Future<String> readTextFromFile(String path) async {
  final recognizer = TextRecognizer(script: TextRecognitionScript.latin);
  try {
    final result = await recognizer.processImage(InputImage.fromFilePath(path));
    return result.text;
  } finally {
    // The recognizer holds a native model. Not closing it leaks it for
    // the life of the process, which on a phone is the life of the app.
    await recognizer.close();
  }
}

/// The same, for a file that only exists in storage.
///
/// ML Kit takes a path rather than bytes, so an attachment pulled back
/// down has to land on disk first. The copy is scratch and goes at the
/// end — the photograph itself is already in the bucket.
Future<String> readTextFromBytes(Uint8List bytes) async {
  final dir = await getTemporaryDirectory();
  final file = File(
      '${dir.path}/scan-${DateTime.now().microsecondsSinceEpoch}.img');
  try {
    await file.writeAsBytes(bytes);
    return await readTextFromFile(file.path);
  } finally {
    try {
      await file.delete();
    } catch (_) {
      // A temp file that outlives its read is the operating system's
      // problem, not a reason to fail a scan that worked.
    }
  }
}
