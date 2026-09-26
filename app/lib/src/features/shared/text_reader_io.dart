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

/// ML Kit takes an image and nothing else.
///
/// A browser has `pdf.js` and can do both halves — read the text out of
/// a typed PDF, render a photographed one — but that is 1.8MB of
/// JavaScript with no equivalent here worth carrying. On a phone the
/// camera is in your hand anyway, which is what the refusal says.
bool get onDeviceReadsPdf => false;

Future<String> readTextFromPdfBytes(Uint8List bytes) => throw UnsupportedError(
      'A PDF cannot be read on this device.',
    );

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

/// Pages of a PDF, drawn as pictures, for showing one inside the app.
///
/// `pdf.js` is a browser library and there is none of it here, so on a
/// phone this throws rather than pretending. The caller asks
/// [canRenderPdfPages] first and says something useful instead.
Future<List<Uint8List>> pdfPageImages(Uint8List bytes, {int maxPages = 20}) =>
    throw UnsupportedError('A PDF cannot be drawn on this device.');

/// Whether a PDF can be DRAWN here, as opposed to read.
///
/// False on a phone: `pdf.js` is vendored for the browser, and nothing
/// in this build renders a PDF page. Separate from
/// [onDeviceReadsPdf] -- which is about the same library and happens
/// to agree today -- because they are different questions and a future
/// native renderer would change one without the other.
bool get canRenderPdfPages => false;
