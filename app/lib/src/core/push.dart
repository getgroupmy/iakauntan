/// Making a device buzz when the app is closed.
///
/// A browser is reached with a VAPID key pair generated locally and
/// nothing else — no Google project, no third party who can read the
/// traffic. An iPhone is reached the same way, with Apple's own `.p8`
/// key instead (`0657`) — see `push_io.dart`. Android needs Firebase,
/// which needs an account that does not exist yet, so `push_io.dart`
/// answers `unsupported` for it rather than pretending.
///
/// The sender is `supabase/functions/send-push`, and the payload is
/// encrypted to this browser's own keys on the way; an iPhone's is not
/// encrypted the same way because it never leaves Apple's own network.
library;

export 'push_io.dart' if (dart.library.js_interop) 'push_web.dart';
export 'push_types.dart';
