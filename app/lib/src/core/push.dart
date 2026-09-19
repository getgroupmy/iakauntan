/// Making a device buzz when the app is closed.
///
/// Two halves behind one signature, chosen at compile time: a browser
/// gets `push_web.dart`, anything else gets `push_native.dart`.
///
/// Neither of them goes through a third party where it does not have
/// to. A browser is reached with a VAPID key pair generated locally,
/// and the payload is encrypted to that browser's own keys under RFC
/// 8291, so the push service carries ciphertext it cannot read. An
/// iPhone is reached with an Apple `.p8` addressed straight at APNs —
/// no Google project in the middle of an Apple conversation, and the
/// only way to send the PushKit push a real CallKit ring needs.
///
/// Android is the exception and says so: Firebase is Google's transport
/// all the way down, there is no direct equivalent, and it needs a
/// `google-services.json` that cannot live in this repository. So
/// `push_native.dart` answers `unsupported` there rather than
/// registering a device nothing can send to.
///
/// The sender is `supabase/functions/send-push`. `0657` and `0658` are
/// the register, and `docs/push-notifications.md` is the argument.
library;

export 'push_native.dart' if (dart.library.js_interop) 'push_web.dart';
export 'push_types.dart';
