import 'dart:typed_data';

// What the web gets. The scanner is ML Kit on Android and VisionKit on
// iOS; a browser has neither, and the plugin reaches `dart:io` on the
// way to them, so this exists to keep the web build compiling rather
// than merely to fail politely.
class ScannedPage {
  const ScannedPage({required this.bytes, required this.path});

  final Uint8List bytes;
  final String path;
}

bool get docScannerLikely => false;

Future<ScannedPage?> scanDocumentPage() => throw UnsupportedError(
      'Scanning a document needs the phone or tablet app.',
    );

bool isScannerUnavailable(Object error) => true;
