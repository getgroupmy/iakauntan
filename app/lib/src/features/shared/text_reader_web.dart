/// Tesseract, in the browser, at nobody's expense.
///
/// The other four readers are somebody's API and somebody's invoice.
/// This one is an open-source engine compiled to WebAssembly and served
/// from our own origin: no key, no per-scan charge, no vendor, and the
/// photograph is decoded in the tab rather than posted anywhere. It is
/// the same bargain ML Kit makes on a phone, which is why the two sit
/// behind one choice in Settings — "on this device" means the machine in
/// front of the person, whatever that machine is.
///
/// **Everything is served locally.** `tesseract.js` will happily fetch
/// its worker, its WebAssembly core and its language model from a CDN,
/// which would mean a third party learns every time somebody reads a
/// receipt and could serve different code tomorrow. All of it is
/// vendored under `web/tesseract/` and the paths below point there. That
/// is what the ~8MB in the repository buys.
///
/// **It reads printing, not documents.** What comes back is text, and
/// `receipt_text.dart` turns it into fields — the same parser the phone
/// uses, so a receipt read on a laptop and one read on a phone produce
/// the same expense.
library;

import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

/// Where the vendored engine lives, relative to the document base.
const _base = 'tesseract';

@JS('Tesseract')
external JSObject? get _tesseractOrNull;

extension type _Tesseract._(JSObject _) implements JSObject {
  external JSPromise<_RecognizeResult> recognize(
      JSAny image, String langs, JSObject options);
}

extension type _RecognizeResult._(JSObject _) implements JSObject {
  external _RecognizeData get data;
}

extension type _RecognizeData._(JSObject _) implements JSObject {
  external String get text;
}

/// Whether the engine is on the page.
///
/// The script tag is in `web/index.html`, so this is false only if that
/// were removed or the file failed to load — worth answering rather than
/// assuming, because the failure otherwise arrives as an
/// incomprehensible interop error at the moment somebody presses Scan.
bool get onDeviceReaderAvailable => _tesseractOrNull != null;

/// There is no file system here worth the name; the web path always
/// arrives as bytes.
Future<String> readTextFromFile(String path) => throw UnsupportedError(
      'In a browser a document is read from its bytes, not from a path.',
    );

Future<String> readTextFromBytes(Uint8List bytes) async {
  final engine = _tesseractOrNull;
  if (engine == null) {
    throw StateError(
      'The reader did not load. Reload the page and try again.',
    );
  }

  final options = JSObject()
    // Each of these would otherwise default to a CDN.
    ..setProperty('workerPath'.toJS, '$_base/worker.min.js'.toJS)
    ..setProperty('corePath'.toJS, '$_base/core'.toJS)
    ..setProperty('langPath'.toJS, '$_base/lang'.toJS)
    // The model is served gzipped — 4.1MB down to 1.9MB, which on a
    // Malaysian mobile connection is the difference between a pause and
    // a wait. Fetched once and then in the browser's cache.
    ..setProperty('gzip'.toJS, true.toJS);

  // A data URL rather than a blob: `tesseract.js` takes either, and a
  // data URL needs no object URL to revoke afterwards — one less thing
  // to leak on a screen somebody scans a dozen receipts from.
  final image = 'data:image/jpeg;base64,${base64Encode(bytes)}';

  final result =
      await (engine as _Tesseract).recognize(image.toJS, 'eng', options).toDart;
  return result.data.text;
}
