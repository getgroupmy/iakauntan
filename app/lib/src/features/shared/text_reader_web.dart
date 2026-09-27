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

import '../../core/error_text.dart';

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
    throw StateError('The $what could not be fetched from $url (${errorText(e)}).');
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

/// Whether a PDF can be read here without sending it anywhere.
///
/// True in a browser and false on a phone: ML Kit takes an image and
/// nothing else, while `pdf.js` gives a browser both halves of the
/// problem — the text of a PDF that was typed, and a rendering of one
/// that was photographed.
bool get onDeviceReadsPdf => true;

@JS('loadPdfjs')
external JSPromise<_PdfLib> _loadPdfjs();

extension type _PdfLib._(JSObject _) implements JSObject {
  external _LoadingTask getDocument(JSObject src);
}

extension type _LoadingTask._(JSObject _) implements JSObject {
  external JSPromise<_PdfDoc> get promise;
}

extension type _PdfDoc._(JSObject _) implements JSObject {
  external int get numPages;
  external JSPromise<_PdfPage> getPage(int number);
  external JSPromise<JSAny?> destroy();
}

extension type _PdfPage._(JSObject _) implements JSObject {
  external JSPromise<_TextContent> getTextContent();
  external _Viewport getViewport(JSObject options);
  external _RenderTask render(JSObject options);
}

extension type _RenderTask._(JSObject _) implements JSObject {
  external JSPromise<JSAny?> get promise;
}

extension type _Viewport._(JSObject _) implements JSObject {
  external double get width;
  external double get height;
}

extension type _TextContent._(JSObject _) implements JSObject {
  external JSArray<_TextItem> get items;
}

extension type _TextItem._(JSObject _) implements JSObject {
  external String? get str;
  external bool? get hasEOL;
}

/// How many pages of a PDF are worth reading.
///
/// A bill is one page and occasionally two; a contract is forty, and
/// rendering forty pages to read a total off the first would be a way
/// of making somebody wait for nothing.
const _pagesRead = 3;

/// Below this much text, the PDF is a photograph in a wrapper.
///
/// A scanned page still yields a few stray characters — a fax header, a
/// page number stamped by whatever produced it — so "no text at all" is
/// the wrong test. A real bill has hundreds of characters on it.
const _typedIfOver = 60;

/// The printing in a PDF, read whichever way that PDF calls for.
///
/// Two quite different documents share the extension. One was typed and
/// carries its text: reading that text is exact, instant, and better
/// than any OCR of a picture of it. The other is a photograph in a PDF
/// wrapper and carries no text at all, so the page is rendered and
/// handed to Tesseract like any other picture.
///
/// Which one this is decides itself, by how much text came out.
Future<String> readTextFromPdfBytes(Uint8List bytes) async {
  final _PdfLib lib;
  try {
    lib = await _loadPdfjs().toDart;
  } catch (e) {
    throw StateError(
      'The PDF reader did not load (${errorText(e)}). Reload the page and try again.',
    );
  }

  // `getDocument` takes the bytes, so nothing is fetched and nothing
  // leaves the tab.
  final src = JSObject()..setProperty('data'.toJS, bytes.toJS);
  final doc = await lib.getDocument(src).promise.toDart;

  try {
    final pages = doc.numPages < _pagesRead ? doc.numPages : _pagesRead;
    if (pages < 1) throw StateError('That PDF has no pages in it.');

    // The typed reading first, because it costs one pass and no
    // rendering, and where it works it is not an approximation.
    final typed = StringBuffer();
    for (var n = 1; n <= pages; n++) {
      final page = await doc.getPage(n).toDart;
      final content = await page.getTextContent().toDart;
      for (final item in content.items.toDart) {
        final text = item.str;
        if (text == null) continue;
        typed.write(text);
        // `hasEOL` is what keeps this readable by the receipt parser,
        // which works a line at a time. Without it a whole bill arrives
        // as one line and every label runs into its own figure.
        typed.write(item.hasEOL == true ? '\n' : ' ');
      }
    }

    final asTyped = typed.toString();
    if (asTyped.replaceAll(RegExp(r'\s'), '').length >= _typedIfOver) {
      return asTyped;
    }

    // Nothing worth having, so it is a photograph. Render and read.
    final engine = _tesseractOrNull;
    if (engine == null) {
      throw StateError(
        'That PDF is a scan rather than a typed document, and the reader '
        'that handles pictures did not load. Reload the page and try again.',
      );
    }
    await _mustReachEngine();

    final read = StringBuffer();
    for (var n = 1; n <= pages; n++) {
      final page = await doc.getPage(n).toDart;
      read.write(await _readRenderedPage(engine, page));
      read.write('\n');
    }
    return read.toString();
  } finally {
    // The worker holds the document open otherwise, and a second scan
    // in the same tab then competes with the first for memory.
    try {
      await doc.destroy().toDart;
    } catch (_) {}
  }
}

/// One page of a PDF, drawn and then read as a picture.
Future<String> _readRenderedPage(JSObject engine, _PdfPage page) async {
  // A PDF page is measured in points, so a bill is 595 wide at scale 1
  // — far too coarse for OCR. Scaled to roughly the same 2400px the
  // camera path settles on, which is around 200dpi on A4.
  final unit = page.getViewport(JSObject()..setProperty('scale'.toJS, 1.0.toJS));
  final longest = unit.width > unit.height ? unit.width : unit.height;
  final scale = longest > 0 ? (_longestEdge / longest).clamp(1.0, 4.0) : 2.0;
  final viewport =
      page.getViewport(JSObject()..setProperty('scale'.toJS, scale.toJS));

  final canvas = _createElement('canvas') as _Canvas
    ..width = viewport.width.round()
    ..height = viewport.height.round();
  final context = canvas.getContext('2d');
  if (context == null) {
    throw StateError('This browser would not give us a drawing surface.');
  }

  await page
      .render(JSObject()
        ..setProperty('canvasContext'.toJS, context)
        ..setProperty('viewport'.toJS, viewport))
      .promise
      .toDart;

  final result = await (engine as _Tesseract)
      .recognize(canvas.toDataURL('image/jpeg', 0.92).toJS, 'eng', _options())
      .toDart;
  return result.data.text;
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

/// Checks the three files the engine will go and fetch for itself.
///
/// Before handing over to something that will only ever say "Load
/// failed", whichever of the three is missing.
Future<void> _mustReachEngine() async {
  final core = _corePath;
  await _mustReach('reader', _asset('tesseract/worker.min.js'));
  await _mustReach('recognition engine', core);
  // Not named anywhere we control: the engine's loader asks for the
  // `.wasm` beside its own `.js`, which is why the two sit in one
  // directory rather than in a tidier arrangement that resolved
  // differently inside a worker than it did on the page.
  await _mustReach(
      'recognition engine', core.replaceFirst(RegExp(r'\.js$'), ''));
  await _mustReach(
      'English language model', _asset('tesseract/lang/eng.traineddata'));
}

/// Where the engine should look for each of its own pieces.
JSObject _options() {
  return JSObject()
    // Each of these would otherwise default to a CDN.
    ..setProperty('workerPath'.toJS, _asset('tesseract/worker.min.js').toJS)
    ..setProperty('corePath'.toJS, _corePath.toJS)
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
}

Future<String> readTextFromBytes(Uint8List bytes) async {
  final engine = _tesseractOrNull;
  if (engine == null) {
    throw StateError(
      'The reader did not load. Reload the page and try again.',
    );
  }
  await _mustReachEngine();

  // A data URL rather than a blob: `tesseract.js` takes either, and a
  // data URL needs no object URL to revoke afterwards — one less thing
  // to leak on a screen somebody scans a dozen receipts from.
  final image = await _asReadableJpeg(bytes);

  final result = await (engine as _Tesseract)
      .recognize(image.toJS, 'eng', _options())
      .toDart;
  return result.data.text;
}

/// Whether a PDF can be DRAWN here, as opposed to read.
///
/// True in a browser, because `pdf.js` is vendored under `web/pdfjs/`
/// and has been for two years. Separate from [onDeviceReadsPdf] --
/// which is about the same library and happens to agree today --
/// because they are different questions and a future native renderer
/// would change one without the other.
bool get canRenderPdfPages => true;

/// How wide a page is drawn for LOOKING at.
///
/// Smaller than the 2400px the OCR path uses. That number exists so
/// Tesseract can resolve small print; this one exists so a person can
/// read a bill on a phone, and four times the pixels would be four
/// times the memory and the wait for no visible gain.
const _viewEdge = 1400.0;

/// Pages of a PDF, drawn as PNG bytes, for showing one inside the app.
///
/// ## Why bytes rather than a link
///
/// The four places this replaces each minted a SIGNED URL and handed it
/// to the external browser. That put a working link to a private
/// document into another application's address bar, its history, and
/// whatever else can read a tab -- for ten minutes, forwardable, on a
/// bank statement. Asked for as "should not open using external browser
/// or app ... to avoid exposure of link and addresses".
///
/// `getDocument` takes the bytes, exactly as `readTextFromPdfBytes`
/// does, so nothing is fetched and no URL exists to leak.
///
/// [maxPages] stops a forty-page contract from becoming forty
/// full-size bitmaps in memory at once. The caller says how many were
/// left out rather than pretending the document ended.
Future<List<Uint8List>> pdfPageImages(Uint8List bytes, {int maxPages = 20}) async {
  final _PdfLib lib;
  try {
    lib = await _loadPdfjs().toDart;
  } catch (e) {
    throw StateError(
      'The PDF viewer did not load (${errorText(e)}). Reload the page and try again.',
    );
  }

  final src = JSObject()..setProperty('data'.toJS, bytes.toJS);
  final doc = await lib.getDocument(src).promise.toDart;
  try {
    final pages = doc.numPages < maxPages ? doc.numPages : maxPages;
    final out = <Uint8List>[];
    for (var n = 1; n <= pages; n++) {
      final page = await doc.getPage(n).toDart;
      out.add(await _drawPage(page));
    }
    return out;
  } finally {
    await doc.destroy().toDart;
  }
}

Future<Uint8List> _drawPage(_PdfPage page) async {
  final unit = page.getViewport(JSObject()..setProperty('scale'.toJS, 1.0.toJS));
  final longest = unit.width > unit.height ? unit.width : unit.height;
  final scale = longest > 0 ? (_viewEdge / longest).clamp(1.0, 3.0) : 1.5;
  final viewport =
      page.getViewport(JSObject()..setProperty('scale'.toJS, scale.toJS));

  final canvas = _createElement('canvas') as _Canvas
    ..width = viewport.width.round()
    ..height = viewport.height.round();
  final context = canvas.getContext('2d');
  if (context == null) {
    throw StateError('This browser would not give us a drawing surface.');
  }

  await page
      .render(JSObject()
        ..setProperty('canvasContext'.toJS, context)
        ..setProperty('viewport'.toJS, viewport))
      .promise
      .toDart;

  // PNG rather than JPEG. This is a document with thin black strokes on
  // white, which is where JPEG's artefacts are ugliest and where PNG
  // compresses best anyway.
  // The quality argument is ignored for PNG, which is lossless, and the
  // binding requires it.
  return _dataUrlBytes(canvas.toDataURL('image/png', 1.0));
}

/// The bytes inside a `data:` URL, without going near the network.
Uint8List _dataUrlBytes(String dataUrl) {
  final comma = dataUrl.indexOf(',');
  if (comma < 0) throw StateError('The page did not draw.');
  return base64Decode(dataUrl.substring(comma + 1));
}
