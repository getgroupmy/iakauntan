// Reading printing off a photograph, on whatever this is running on.
//
// Two implementations and no third: ML Kit where there is a phone under
// the app, Tesseract compiled to WebAssembly where there is a browser.
// Both run on the machine in front of the person — no key, no per-scan
// charge, and the photograph does not leave it. That is what makes "on
// this device" a single choice in Settings rather than one that works on
// a phone and apologises on a laptop.
//
// The conditional export is not a nicety. ML Kit reaches `dart:io`
// through its commons package, so a web build that imports it does not
// compile; and the Tesseract side is `dart:js_interop`, which nothing
// else can. Each side is only ever compiled where it belongs.
export 'text_reader_web.dart' if (dart.library.io) 'text_reader_io.dart';
