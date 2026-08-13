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

/// Where the vendored engine lives.
///
/// Absolute, resolved against the document base, and that is not
/// tidiness. `tesseract.js` fetches the worker and then runs the core
/// and the language model fetches *inside* that worker — where a
/// relative URL resolves against the worker's own script, not the page.
/// On a route like `/purchases/bill` the relative form went looking in
/// the wrong place and came back `NetworkError: Load failed`, which
/// names the symptom and nothing else.
String _asset(String path) => Uri.parse(_baseUri).resolve(path).toString();

@JS('document.baseURI')
external String get _baseUri;

@JS('Tesseract')
external JSObject? get _tesseractOrNull;

@JS('fetch')
external JSPromise<_Response> _fetch(String url, JSObject init);

extension type _Response._(JSObject _) implements JSObject {
  external bool get ok;
  external int get status;
}

/// Checks an asset is actually reachable, and says which one is not.
///
/// `tesseract.js` fetches its worker, its core and its language model
/// itself, and reports any of them failing as the browser's generic
/// message — in Safari, `NetworkError: Load failed`. That names the
/// symptom and nothing else: three files, one of them missing, and no
/// way to tell which without a console.
///
/// A HEAD apiece costs almost nothing and turns that into a sentence
/// somebody can act on.
Future<void> _mustReach(String what, String url) async {
  final init = JSObject()..setProperty('method'.toJS, 'HEAD'.toJS);
  final int status;
  try {
    status = (await _fetch(url, init).toDart).status;
  } catch (e) {
    throw StateError('The $what could not be fetched from $url ($e).');
  }
  if (status < 200 || status >= 300) {
    throw StateError('The $what is not being served: $url returned $status.');
  }
}

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

  // Before handing over to an engine that will only say "Load failed".
  final worker = _asset('tesseract/worker.min.js');
  await _mustReach('reader', worker);
  await _mustReach(
      'recognition engine', _asset('tesseract/core/tesseract-core-lstm.wasm'));
  await _mustReach(
      'English language model', _asset('tesseract/lang/eng.traineddata'));

  final options = JSObject()
    // Each of these would otherwise default to a CDN.
    ..setProperty('workerPath'.toJS, worker.toJS)
    ..setProperty('corePath'.toJS, _asset('tesseract/core').toJS)
    ..setProperty('langPath'.toJS, _asset('tesseract/lang').toJS)
    // Loaded straight from our own origin rather than fetched into a
    // blob and run from that. A blob worker resolves its own imports
    // against the blob, not the page, and is the first thing a strict
    // `worker-src` refuses — two failure modes removed for the cost of
    // one flag.
    ..setProperty('workerBlobURL'.toJS, false.toJS)
    // Served uncompressed, and `gzip: false` to match. The 1.9MB
    // gzipped model is the smaller download on paper, but a host that
    // sets `Content-Encoding: gzip` on a `.gz` file has the browser
    // decompress it before the reader sees it — which then tries to
    // decompress it again and fails. 4.1MB once, cached for a year by
    // the header rules in the deploy config, beats a size saving that
    // depends on what a CDN decides to do with a file extension.
    ..setProperty('gzip'.toJS, false.toJS);

  // A data URL rather than a blob: `tesseract.js` takes either, and a
  // data URL needs no object URL to revoke afterwards — one less thing
  // to leak on a screen somebody scans a dozen receipts from.
  final image = 'data:image/jpeg;base64,${base64Encode(bytes)}';

  final result =
      await (engine as _Tesseract).recognize(image.toJS, 'eng', options).toDart;
  return result.data.text;
}
