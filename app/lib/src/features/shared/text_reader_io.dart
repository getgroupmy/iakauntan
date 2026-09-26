import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform;
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdfx/pdfx.dart';

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

/// How wide a page is drawn for LOOKING at.
///
/// The same number the browser side uses, so a bill looks the same on a
/// phone as on a laptop. Larger would be more memory and a longer wait
/// for detail a screen cannot show.
const _viewEdge = 1400.0;

/// Pages of a PDF, drawn as PNG bytes, for showing one inside the app.
///
/// ## Why this is here at all
///
/// `pdf.js` is a browser library, so before `pdfx` a PDF could not be
/// drawn on a phone -- and the alternative was handing a signed URL to
/// whatever app claims PDFs, which is the exposure the viewer exists to
/// remove. The package renders from BYTES, which is the whole
/// requirement: nothing is fetched and no URL is created.
///
/// ## And why the browser does not use it
///
/// `pdfx` HAS a web implementation, and that implementation points at
/// `cdn.jsdelivr.net` for its character maps. This repository vendors
/// `pdf.js` and Tesseract under `web/` precisely so that reading a
/// document tells nobody -- so the conditional export keeps the browser
/// on the vendored copy and this file is the only caller of `pdfx`.
///
/// Registering the plugin fetches nothing: `PdfxPlugin.registerWith`
/// assigns a platform instance and does no more. The CDN is reached
/// only by opening a document through `pdfx` on web, which nothing
/// here does.
///
/// [maxPages] stops a forty-page contract from becoming forty full-size
/// bitmaps at once. The caller says how many were left out rather than
/// pretending the document ended.
Future<List<Uint8List>> pdfPageImages(Uint8List bytes,
    {int maxPages = 20}) async {
  final doc = await PdfDocument.openData(bytes);
  try {
    final count = doc.pagesCount < maxPages ? doc.pagesCount : maxPages;
    final out = <Uint8List>[];
    for (var n = 1; n <= count; n++) {
      final page = await doc.getPage(n);
      try {
        final longest =
            page.width > page.height ? page.width : page.height;
        final scale =
            longest > 0 ? (_viewEdge / longest).clamp(1.0, 3.0) : 1.5;
        final image = await page.render(
          width: page.width * scale,
          height: page.height * scale,
          // PNG for the reason the browser side gives: a document is
          // thin black strokes on white, which is where JPEG's
          // artefacts are ugliest and where PNG compresses best.
          format: PdfPageImageFormat.png,
        );
        final drawn = image?.bytes;
        if (drawn != null) out.add(drawn);
      } finally {
        await page.close();
      }
    }
    return out;
  } finally {
    await doc.close();
  }
}

/// Whether a PDF can be DRAWN here, as opposed to read.
///
/// True since `pdfx` arrived. Separate from [onDeviceReadsPdf], which
/// is about READING a PDF's text on this device and is still false on a
/// phone -- ML Kit takes an image and nothing else. They are different
/// questions and this is the commit that made them disagree.
bool get canRenderPdfPages => true;
