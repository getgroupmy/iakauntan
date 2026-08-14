/// The bytes of a just-finished recording.
///
/// `record` hands back a location rather than the audio, and what that
/// location *is* differs by platform: a file path on Android and iOS, a
/// blob URL in the browser. Reading a file needs `dart:io`, which the web
/// build cannot see; reading a blob needs `dart:js_interop`, which the
/// mobile build cannot see. Same shape as `download.dart` above it.
library;

export 'recorded_audio_io.dart'
    if (dart.library.js_interop) 'recorded_audio_web.dart';
