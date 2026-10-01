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
/// Android is the exception, and says which kind of exception it is.
/// FCM is Google's transport all the way down, there is no direct
/// equivalent, and it needs a `google-services.json` that cannot live
/// in this repository — so the Firebase client is compiled in on every
/// build and configured on almost none. A build with no project
/// answers `notConfigured` rather than `unsupported`: the handset is
/// perfectly capable, this copy of the app has nowhere to register.
/// `app/android/app/build.gradle.kts` is where that conditional lives.
///
/// The sender is `supabase/functions/send-push`. `0657` and `0658` are
/// the register, and `docs/push-notifications.md` is the argument.
library;

export 'push_native.dart' if (dart.library.js_interop) 'push_web.dart';
export 'push_types.dart';
