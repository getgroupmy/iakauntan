import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform;
import 'package:flutter/services.dart'
    show MethodChannel, MissingPluginException, PlatformException;
import 'package:flutter_doc_scanner/flutter_doc_scanner.dart';
import 'package:path_provider/path_provider.dart';

/// One scanned page: the bytes, and a real file to hand a reader.
class ScannedPage {
  const ScannedPage({required this.bytes, required this.path});

  final Uint8List bytes;

  /// Always a path this process can open. On Android that means a copy
  /// this app wrote, not the URI the scanner returned — see below.
  final String path;
}

/// The scanner exists on Android and iOS and nowhere else.
///
/// On Android it is delivered through Google Play services, so a device
/// without them — a Huawei, a de-Googled build, an emulator image
/// without Play — will fail at the call rather than here. That failure
/// is caught and turned back into the plain camera by the caller, which
/// is why this is `likely` and not `available`.
bool get docScannerLikely =>
    defaultTargetPlatform == TargetPlatform.android ||
    defaultTargetPlatform == TargetPlatform.iOS;

/// Reads a `content://` URI through Android's ContentResolver.
///
/// ML Kit's Document Scanner returns FileProvider URIs owned by another
/// package. Dart's `File` cannot open one and neither can ML Kit's
/// `InputImage.fromFilePath` — the grant that makes them readable is
/// attached to the URI and understood by the resolver alone. This is the
/// Kotlin in `MainActivity`, reached over a channel.
const _content = MethodChannel('my.iakauntan.iakauntan/content');

Future<Uint8List> _readContentUri(String uri) async {
  final bytes = await _content.invokeMethod<Uint8List>(
    'readContentUri',
    {'uri': uri},
  );
  if (bytes == null) throw Exception('The scan could not be read back.');
  return bytes;
}

/// Opens the scanner and returns the single page it produced.
///
/// One page, and the automatic single-picture flow: this is a receipt on
/// a counter, not a contract. Multi-page would return several files and
/// give the rest of the app a list where it expects a document.
///
/// Returns null when the person backed out, which is not an error.
Future<ScannedPage?> scanDocumentPage() async {
  final result = await FlutterDocScanner().getScannedDocumentAsImages(
    page: 1,
    useAutomaticSinglePictureProcessing: true,
  );
  final source = result?.images.firstOrNull;
  if (source == null) return null;

  // The shape of what comes back differs by platform, and this is the
  // whole reason this file exists. iOS hands over a file path in the
  // app's own container. Android hands over a content URI belonging to
  // somebody else's provider, readable only through the resolver and
  // only for as long as the grant lasts — so it is read *now* and
  // copied somewhere this app owns, rather than kept as a reference
  // that will stop working.
  final Uint8List bytes;
  if (source.startsWith('content://')) {
    bytes = await _readContentUri(source);
  } else {
    final file = File(source.replaceFirst('file://', ''));
    bytes = await file.readAsBytes();
  }

  final dir = await getTemporaryDirectory();
  final copy = File(
      '${dir.path}/scanned-${DateTime.now().microsecondsSinceEpoch}.jpg');
  await copy.writeAsBytes(bytes);
  return ScannedPage(bytes: bytes, path: copy.path);
}

/// Whether a failure is the scanner being absent rather than broken.
///
/// Play services missing, or the API not installed on this device: both
/// mean "use the camera instead", and neither is worth showing somebody
/// as an error. Anything else is a real failure and is reported.
bool isScannerUnavailable(Object error) {
  if (error is DocScanException) {
    return error.code == DocScanException.codeUnsupported ||
        error.code == 'unavailable' ||
        error.code == 'sdk_unavailable';
  }
  if (error is PlatformException) {
    return error.code == 'unavailable' || error.code == 'sdk_unavailable';
  }
  if (error is MissingPluginException) return true;
  return false;
}
