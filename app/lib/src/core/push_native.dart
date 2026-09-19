/// Push on everything that is not a browser.
///
/// Which today means iOS, straight to Apple, and nothing else.
///
/// ## Why iOS is here and Android is not
///
/// An iPhone can be reached with an Apple `.p8` and no third party —
/// `supabase/functions/_shared/apns.ts` is the sender and `0657` is the
/// register. Android has no equivalent: Firebase is Google's transport
/// all the way down, it needs a `google-services.json` that cannot live
/// in a public repository, and the plugin that reads it pulls the whole
/// Firebase SDK into the build. So Android answers `unsupported` here
/// rather than pretending, exactly as this file did for both platforms
/// before iOS was built.
///
/// ## Two tokens, and why the app asks for both
///
/// iOS issues an APNs device token for alerts and a SEPARATE PushKit
/// token for calls, and only the second can produce the full-screen
/// CallKit ring people expect a phone to make. They differ in more than
/// their value:
///
///   * the alert token exists only once the person has granted
///     notification permission, and is gone if they revoke it;
///   * the PushKit token needs no permission at all and arrives
///     whether or not anybody was asked.
///
/// So `subscribeToPush` can return one, both, or neither, and the thing
/// it must never do is return one labelled as the other — a message
/// sent to a PushKit token gets the app killed by iOS. `0658` carries
/// the whole argument; here it is one `transport` string per token.
///
/// ## Permission gates BOTH, although iOS only gates one
///
/// PushKit would let this app ring a handset whose owner refused
/// notifications, and that is not a loophole worth taking. Somebody who
/// says no to being notified has not said yes to a full-screen ring,
/// which is the more intrusive of the two. So nothing is registered at
/// all until the answer is yes, and the refusal is honoured in the
/// direction the person meant it rather than the direction the platform
/// happens to enforce.
///
/// ## And the native side does not yet hand one over
///
/// `AppDelegate.swift` registers for alerts and NOT for PushKit, and
/// its header says why at length: iOS kills an app that receives a VoIP
/// push without reporting it to CallKit, so PushKit ships in the commit
/// that brings a `CXProvider` and not before. The `apns_voip` branch
/// here is not speculative — `0658` stores it, `send-push` routes it,
/// and the tests below drive it — it simply has no producer yet.
///
/// ## `currentSurface`, not `Platform.isIOS`
///
/// Both answer the same question on a handset, and `surface.dart` is
/// where this codebase answers it once. Only that one can be overridden
/// in a test, which is the difference between this file being covered
/// and being hoped about.
library;

import 'package:flutter/services.dart'
    show MethodChannel, MissingPluginException, PlatformException;

import 'push_types.dart';
import 'surface.dart';


/// The channel `AppDelegate.swift` answers on.
///
/// The bundle identifier, as every channel in this app is named — see
/// `doc_scanner_io.dart`, whose channel breaks SILENTLY if it drifts
/// from the one the native side registers. Both are listed in
/// `docs/handoff.md` among the places an Application ID change has to
/// touch together.
const pushChannel = MethodChannel('my.iakauntan.iakauntan/push');

/// Whether this build has a native half at all.
bool get _capable => currentSurface == Surface.ios;

/// What iOS says about notification permission, mapped to a status.
///
/// `provisional` is authorisation: it is what iOS grants an app that
/// asked for quiet notifications, and they are delivered. Treating it
/// as "not asked yet" would re-prompt somebody who had already said a
/// qualified yes.
PushStatus statusFor(String? authorization, {required bool haveToken}) {
  return switch (authorization) {
    'denied' => PushStatus.denied,
    'authorized' || 'provisional' => haveToken
        ? PushStatus.on
        // Permission survives a registration that Apple has since
        // dropped, and somebody looking at "on" with no token is
        // looking at a lie. The same reasoning as the web half.
        : PushStatus.askable,
    _ => PushStatus.askable,
  };
}

/// Ask the native side something, or answer for a platform that has no
/// native side.
///
/// A [MissingPluginException] is the case that matters: an app whose
/// Dart has been updated past its `AppDelegate` — a hot restart onto an
/// older build, or an iOS target somebody forgot to rebuild. It is not
/// an error to show anybody, it is this device being unable to, which
/// is what `unsupported` already means.
Future<Map<String, dynamic>?> _ask(
  String method, [
  Map<String, dynamic>? arguments,
]) async {
  if (!_capable) return null;
  try {
    final result = await pushChannel.invokeMapMethod<String, dynamic>(
      method,
      arguments,
    );
    return result;
  } on MissingPluginException {
    return null;
  } on PlatformException {
    return null;
  }
}

/// The VAPID key is a browser's business and is ignored here.
///
/// Kept in the signature because `push.dart` exports one of these two
/// files and the caller cannot know which. What decides whether an
/// iPhone can be reached is four secrets on the server, which the app
/// cannot see — so this never answers `notConfigured`; an unreachable
/// handset shows up as a notification that never arrives, and
/// `send-push` reports it in its own response.
Future<PushStatus> pushStatus(String vapidPublicKey) async {
  if (!_capable) return PushStatus.unsupported;
  final answer = await _ask('status');
  if (answer == null) return PushStatus.unsupported;
  return statusFor(
    answer['authorization'] as String?,
    haveToken: (answer['alert'] as String?)?.isNotEmpty ?? false,
  );
}

/// Register this handset, asking for permission only when told to.
///
/// `ask` is not a convenience. iOS asks once and once only: an app that
/// is refused cannot raise the prompt again, and the person has to go
/// to Settings. So the app never asks on start-up — it asks when
/// somebody presses the button, and re-registers silently after that.
///
/// Returns both tokens where both exist, and nothing at all where
/// permission was refused — see the note on PushKit above. One token on
/// its own is an ordinary outcome too: the two arrive from two Apple
/// services at two moments and either may still be in flight.
Future<List<PushRegistration>> subscribeToPush(
  String vapidPublicKey, {
  bool ask = false,
}) async {
  if (!_capable) return const [];
  final answer = await _ask('register', {'ask': ask});
  if (answer == null) return const [];

  final authorization = answer['authorization'] as String?;
  if (authorization != 'authorized' && authorization != 'provisional') {
    return const [];
  }

  final deviceId = answer['deviceId'] as String?;
  final label = answer['label'] as String?;
  final alert = answer['alert'] as String?;
  final voip = answer['voip'] as String?;

  return [
    for (final (transport, token) in [('apns', alert), ('apns_voip', voip)])
      if (token != null && token.isNotEmpty)
        PushRegistration(
          token: token,
          platform: 'ios',
          transport: transport,
          deviceId: deviceId,
          label: label,
        ),
  ];
}

/// Every token this handset currently holds, so all of them can be
/// taken off the register together.
Future<List<String>> currentPushTokens() async {
  final answer = await _ask('tokens');
  if (answer == null) return const [];
  return [
    for (final key in const ['alert', 'voip'])
      if (answer[key] is String && (answer[key] as String).isNotEmpty)
        answer[key] as String,
  ];
}

/// Stop the OS delivering to this handset.
///
/// Permission is NOT revoked — an app cannot revoke it and should not
/// want to, because asking again is impossible. What this undoes is the
/// registration, which is the part the app owns.
Future<void> unsubscribeFromPush() async {
  await _ask('unregister');
}
