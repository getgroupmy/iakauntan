/// Saving a generated file to the user's machine.
///
/// Only the web build can hand a file to the browser; on Android and iOS
/// there is no equivalent that does not drag in a plugin and a pile of
/// storage permissions, so `saveTextFile` reports that it did nothing and
/// the caller falls back to the clipboard.
library;

export 'download_stub.dart' if (dart.library.js_interop) 'download_web.dart';
