// The on-device reader, or nothing at all.
//
// `google_mlkit_text_recognition` reaches `dart:io` through its commons
// package, so it cannot merely be guarded at runtime — a web build that
// imports it does not compile. Hence the conditional export: the web
// gets a stub that answers "not here", and only a build that has
// `dart:io` ever sees the plugin.
//
// Everything else in the app imports this file and asks
// [onDeviceReaderAvailable] first.
export 'mlkit_reader_stub.dart'
    if (dart.library.io) 'mlkit_reader_io.dart';
