/// Making a device buzz when the app is closed.
///
/// Web only, and deliberately. A browser is reached with a VAPID key
/// pair generated locally and nothing else — no Google project, no
/// Apple account, no third party who can read the traffic. Android and
/// iOS need Firebase and APNs respectively, which need accounts that do
/// not exist yet, so `push_stub.dart` answers `unsupported` rather than
/// pretending.
///
/// The sender is `supabase/functions/send-push`, and the payload is
/// encrypted to this browser's own keys on the way.
library;

export 'push_stub.dart' if (dart.library.js_interop) 'push_web.dart';
export 'push_types.dart';
