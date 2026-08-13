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
///
/// Everything except the language model sits flat in this one directory,
/// which is not untidiness either. The engine's own loader resolves its
/// `.wasm` against a base that is the worker's URL in a worker and the
/// script's URL on a page — one directory makes those two the same
/// answer. The language model is the exception because the code builds
/// that URL from `langPath` explicitly, so it can live in `lang/`.
String _asset(String path) => Uri.parse(_baseUri).resolve(path).toString();

@JS('document.baseURI')
external String get _baseUri;

@JS('Tesseract')
external JSObject? get _tesseractOrNull;

@JS('fetch')
external JSPromise<_Response> _fetch(String url, JSObject init);

@JS('WebAssembly.validate')
external bool _wasmValidate(JSUint8Array bytes);

/// Whether this browser runs WebAssembly SIMD.
///
/// A module whose only function returns a `v128` — twenty-nine bytes that
/// every engine either accepts or rejects, which is the published way to
/// ask. Recognition is several times faster where the answer is yes, and
/// the answer is no on iOS before 16.4, which is still in people's
/// pockets.
bool get _simd => _wasmValidate(Uint8List.fromList(const [
      0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, //
      0x01, 0x05, 0x01, 0x60, 0x00, 0x01, 0x7b, //
      0x03, 0x02, 0x01, 0x00, //
      0x0a, 0x0a, 0x01, 0x08, 0x00, 0x41, 0x00, 0xfd, 0x0f, 0xfd, 0x62, 0x0b,
    ]).toJS);

/// The recognition engine this browser should load.
///
/// Named as a file rather than as the directory holding both, and that is
/// the fix for a fortnight of `NetworkError: Load failed`. Handed a
/// directory, `tesseract.js` picks the variant itself — and its first
/// choice is a *relaxed* SIMD build that ships in the npm package and is
/// not vendored here, so it asked for a file that was never there and
/// reported the 404 as the browser's generic network message. Given a
/// path ending `.js` it loads exactly that and asks for nothing else.
String get _corePath => _asset(
    _simd ? 'tesseract/tesseract-core-simd-lstm.wasm.js'
          : 'tesseract/tesseract-core-lstm.wasm.js');

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

@JS('createImageBitmap')
external JSPromise<_Bitmap> _createImageBitmap(_Blob blob);

@JS('URL.createObjectURL')
external String _objectUrl(_Blob blob);

@JS('URL.revokeObjectURL')
external void _revokeObjectUrl(String url);

@JS('document.createElement')
external JSObject _createElement(String tag);

@JS('Blob')
extension type _Blob._(JSObject _) implements JSObject {
  external factory _Blob(JSArray<JSAny> parts);
}

extension type _Bitmap._(JSObject _) implements JSObject {
  external int get width;
  external int get height;
  external void close();
}

@JS('Image')
extension type _Img._(JSObject _) implements JSObject {
  external factory _Img();
  external set src(String value);
  external JSPromise<JSAny?> decode();
  external int get naturalWidth;
  external int get naturalHeight;
}

extension type _Canvas._(JSObject _) implements JSObject {
  external set width(int value);
  external set height(int value);
  external _Context? getContext(String kind);
  external String toDataURL(String type, double quality);
}

extension type _Context._(JSObject _) implements JSObject {
  external void drawImage(JSObject image, num x, num y, num w, num h);
}

/// The longest edge we hand the engine.
///
/// Not a quality setting so much as a working limit. `image_picker`'s
/// `maxWidth` is mobile-only — on the web it is ignored — so what arrives
/// here is whatever the camera took, which on a current phone is twelve
/// megapixels of thermal receipt. Tesseract would work through all of it
/// in WebAssembly, slowly, and small print survives the reduction: 2400px
/// down a receipt is far more than the ~300dpi the engine wants.
const _longestEdge = 2400;

/// Re-encodes a photograph into something the engine can actually open.
///
/// Leptonica, inside Tesseract, reads JPEG, PNG, BMP and TIFF. An iPhone
/// photographs in **HEIC**, and handing those bytes over gets `Error
/// attempting to read image` — accurate, and no help at all to somebody
/// holding a receipt.
///
/// The browser already knows how to decode everything it can display,
/// HEIC included on Safari, so the picture is decoded here and drawn
/// into a canvas that gives back a JPEG. That fixes the format and the
/// size in one pass, and means the `image/jpeg` this function claims is
/// true rather than assumed.
Future<String> _asReadableJpeg(Uint8List bytes) async {
  final blob = _Blob([bytes.toJS].toJS);

  // `createImageBitmap` where it exists, an `<img>` where it does not or
  // where it refuses the format. Safari has decoded HEIC in an image
  // element far longer than it has anywhere else, so the fallback is the
  // one that matters on the device this failed on.
  JSObject source;
  int width;
  int height;
  _Bitmap? bitmap;
  String? url;
  try {
    bitmap = await _createImageBitmap(blob).toDart;
    source = bitmap;
    width = bitmap.width;
    height = bitmap.height;
  } catch (_) {
    url = _objectUrl(blob);
    final img = _Img()..src = url;
    try {
      await img.decode().toDart;
    } catch (_) {
      _revokeObjectUrl(url);
      throw StateError(
        'This file is not a picture the browser can open. Photograph the '
        'receipt, or attach it as a JPEG or a PNG.',
      );
    }
    source = img;
    width = img.naturalWidth;
    height = img.naturalHeight;
  }

  try {
    if (width == 0 || height == 0) {
      throw StateError('The picture came back empty.');
    }

    // Only ever smaller. Enlarging a small photograph invents detail the
    // engine would then try to read.
    final longest = width > height ? width : height;
    final scale = longest > _longestEdge ? _longestEdge / longest : 1.0;
    final w = (width * scale).round();
    final h = (height * scale).round();

    final canvas = _createElement('canvas') as _Canvas
      ..width = w
      ..height = h;
    final context = canvas.getContext('2d');
    if (context == null) {
      throw StateError('This browser would not give us a drawing surface.');
    }
    context.drawImage(source, 0, 0, w, h);

    // High quality on purpose: the artefacts of a hard-compressed JPEG
    // land exactly on the thin strokes of small print.
    return canvas.toDataURL('image/jpeg', 0.92);
  } finally {
    bitmap?.close();
    if (url != null) _revokeObjectUrl(url);
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
  final core = _corePath;
  await _mustReach('reader', worker);
  await _mustReach('recognition engine', core);
  // Not named anywhere we control: the engine's loader asks for the
  // `.wasm` beside its own `.js`, which is why the two sit in one
  // directory rather than in a tidier arrangement that resolved
  // differently inside a worker than it did on the page.
  await _mustReach('recognition engine',
      core.replaceFirst(RegExp(r'\.js$'), ''));
  await _mustReach(
      'English language model', _asset('tesseract/lang/eng.traineddata'));

  final options = JSObject()
    // Each of these would otherwise default to a CDN.
    ..setProperty('workerPath'.toJS, worker.toJS)
    ..setProperty('corePath'.toJS, core.toJS)
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
  final image = await _asReadableJpeg(bytes);

  final result =
      await (engine as _Tesseract).recognize(image.toJS, 'eng', options).toDart;
  return result.data.text;
}
