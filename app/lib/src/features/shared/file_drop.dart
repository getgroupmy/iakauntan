// Dropping a file onto the window, where there is a window.
//
// Flutter has no drag-and-drop from the desktop built in, and the two
// packages that add it are for desktop embedders rather than the web.
// The browser has had this since 2010 — `dragover` and `drop` on the
// document — and `package:web` is already a dependency, so this is a
// listener rather than a dependency.
//
// The conditional export is the pattern `text_reader.dart` uses and for
// the same reason: the web side is `dart:js_interop`, which nothing
// else can compile. Everywhere else this is a no-op that returns a
// function doing nothing, so a caller never has to ask where it is
// running.
export 'file_drop_stub.dart' if (dart.library.js_interop) 'file_drop_web.dart';
