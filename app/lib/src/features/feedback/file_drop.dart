/// Picking files for a bug report, and dropping them where that works.
///
/// One import for the caller; two implementations underneath, chosen
/// at compile time the same way `captcha.dart` chooses its Turnstile
/// widget.
///
/// **No package for this.** Drag-and-drop of files is a browser thing,
/// and this application ships web, Android and iOS — there is no
/// desktop build to want `desktop_drop` for. The web half is forty
/// lines of `package:web`, which is already a dependency, against a
/// new package in the tree and a new entry for the dependency audit to
/// watch.
library;

export 'file_drop_stub.dart'
    if (dart.library.js_interop) 'file_drop_web.dart';
