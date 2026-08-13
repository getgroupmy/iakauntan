// The scanner UI, or nothing at all.
//
// Same arrangement as `mlkit_reader.dart`, and for the same reason: the
// plugin reaches `dart:io`, so a runtime guard would not save the web
// build. Callers import this and ask `docScannerLikely` first.
export 'doc_scanner_stub.dart' if (dart.library.io) 'doc_scanner_io.dart';
