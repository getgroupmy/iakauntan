/// What the system's own call screen did, brought back into the app.
///
/// On iOS a call can be answered before this application has run a line
/// of Dart. A VoIP push starts the process, `AppDelegate.swift` reports
/// the call to CallKit, and the person taps answer on a full-screen
/// ring that Flutter had nothing to do with — so by the time anything
/// here is listening, the decision has already been made.
///
/// That is why this is a QUEUE and not a stream of live events. The
/// native side appends what happened and nudges; this drains. An event
/// sent down a channel nobody is listening to is dropped without a
/// word, and "nobody is listening" is the ordinary case rather than the
/// edge one.
///
/// Everything below the channel is Swift. Everything above it — which
/// events exist, what a malformed one does, and what the app does with
/// each — is here, and `callkit_test.dart` covers it.
library;

import 'package:flutter/services.dart'
    show MethodCall, MethodChannel, MissingPluginException, PlatformException;

import 'surface.dart';

/// The channel `AppDelegate.swift` answers on.
///
/// Its own, not the push one: push registration is asked for by a
/// screen, and a call arrives whether or not anything is listening.
/// Named after the bundle identifier like every channel in this app —
/// see `docs/handoff.md` for the list of places that have to change
/// together.
const callChannel = MethodChannel('my.iakauntan.iakauntan/calls');

/// What the system's call screen did.
enum CallKitEventKind {
  /// A call is ringing. Not an instruction to do anything — the app
  /// learns about calls from `chat_incoming_calls` as well — but it
  /// arrives sooner, and on a cold start it arrives before any query
  /// could have.
  ringing,

  /// Answered on the system's call screen. The app has to join and open
  /// the call, and must NOT put its own incoming-call sheet in front of
  /// somebody who has already said yes.
  answered,

  /// Declined, or hung up from the system's call screen.
  ended,
}

/// One thing that happened to one call.
class CallKitEvent {
  const CallKitEvent({
    required this.kind,
    required this.callId,
    this.video = false,
    this.caller,
  });

  final CallKitEventKind kind;
  final String callId;
  final bool video;
  final String? caller;

  @override
  String toString() => 'CallKitEvent($kind, $callId, video: $video)';
}

/// Whether this build has a native side at all.
///
/// `currentSurface` rather than `Platform.isIOS`, for the reason
/// `push_native.dart` gives: only the first can be overridden in a
/// test. Android has no CallKit and no equivalent — a full-screen
/// incoming call there is a notification with a full-screen intent,
/// which needs Firebase first.
bool get callKitAvailable => currentSurface == Surface.ios;

/// One event, or null if it is not one this app understands.
///
/// Null rather than an exception, and deliberately: this parses a
/// message from another language across a channel, and the failure that
/// matters is a newer native side sending a kind this build has never
/// heard of. Throwing would lose every OTHER event in the same drain,
/// including the answer somebody is waiting on.
CallKitEvent? parseCallKitEvent(Object? raw) {
  if (raw is! Map) return null;
  final callId = raw['call_id'];
  if (callId is! String || callId.isEmpty) return null;

  final kind = switch (raw['event']) {
    'ringing' => CallKitEventKind.ringing,
    'answered' => CallKitEventKind.answered,
    'ended' => CallKitEventKind.ended,
    _ => null,
  };
  if (kind == null) return null;

  final caller = raw['caller'];
  return CallKitEvent(
    kind: kind,
    callId: callId,
    video: raw['video'] == true,
    caller: caller is String && caller.isNotEmpty ? caller : null,
  );
}

/// Everything in one drain, in the order it happened.
///
/// Order is load-bearing. A call that rang and was then declined while
/// the app was still starting arrives as two events, and acting on the
/// first without the second would open a call screen for a call nobody
/// is on.
List<CallKitEvent> parseCallKitEvents(Object? raw) {
  if (raw is! List) return const [];
  return [
    for (final item in raw)
      if (parseCallKitEvent(item) case final event?) event,
  ];
}

/// Take everything the system has done since the last drain.
///
/// Empty on any platform without a native half, and on a build whose
/// Dart is ahead of its `AppDelegate` — which is a rebuild rather than
/// anything a person can act on.
Future<List<CallKitEvent>> drainCallKitEvents() async {
  if (!callKitAvailable) return const [];
  try {
    return parseCallKitEvents(await callChannel.invokeMethod<List<Object?>>(
      'drain',
    ));
  } on MissingPluginException {
    return const [];
  } on PlatformException {
    return const [];
  }
}

/// Tell the system a call is over, because the app ended it.
///
/// CallKit does not find out by itself. A call it still believes is
/// running is a green bar across the top of the phone that nothing the
/// person does will clear.
Future<void> reportCallKitEnded(String callId) async {
  if (!callKitAvailable) return;
  try {
    await callChannel.invokeMethod<void>('end', {'call_id': callId});
  } on MissingPluginException {
    // Nothing to tell.
  } on PlatformException {
    // Nothing useful to do: the call is over either way, and the worst
    // case is a stale entry the system clears on its own reset.
  }
}

/// Be woken when something happens, and drain.
///
/// The handler ignores what it was sent. The nudge carries no payload
/// on purpose — one delivery path means an event cannot arrive twice,
/// and a second path that could drop messages is worse than no second
/// path at all.
void listenForCallKit(void Function(List<CallKitEvent>) onEvents) {
  if (!callKitAvailable) return;
  callChannel.setMethodCallHandler((MethodCall call) async {
    onEvents(await drainCallKitEvents());
    return null;
  });
}

/// Stop listening. For a widget being disposed, and for the tests.
void stopListeningForCallKit() {
  if (!callKitAvailable) return;
  callChannel.setMethodCallHandler(null);
}
