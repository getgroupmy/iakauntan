import 'dart:async';

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform;
import 'package:flutter/services.dart' show MethodChannel, PlatformException;

import 'push_types.dart';

/// Push notifications on the iPhone, over a MethodChannel to
/// `AppDelegate.swift` — `UNUserNotificationCenter` has no Flutter
/// plugin in this app, because the whole point of `0657` was reaching
/// Apple with nothing else in the middle, and a plugin is a third party.
///
/// Android arrives here too, because `dart.library.io` does not tell the
/// two apart the way `dart.library.js_interop` tells a browser from
/// everything else. It answers `unsupported` throughout: it needs
/// Firebase, and that is still blocked on the secrets
/// `docs/push-notifications.md` names.
///
/// ## PushKit's VoIP token is deliberately NOT here
///
/// Apple requires every VoIP push to be handed to CallKit before the
/// delegate method that receives it returns — miss that consistently and
/// the OS starts terminating the app for it, and can revoke the VoIP
/// entitlement outright. Registering the token without that handler
/// built would trade "a call does not ring" for "a call arrives and the
/// app is punished for not answering it", which is worse. That half
/// stays open in `docs/push-notifications.md` until CallKit's reporting
/// is built alongside it.
const _channel = MethodChannel('my.iakauntan.iakauntan/push');

bool _listening = false;

/// The one remote-token request this file lets be in flight at a time.
/// `registerForRemoteNotifications` returns before Apple answers — the
/// token or the failure arrives later, as its own call FROM native TO
/// this channel — so this is what a caller actually waits on. Shared
/// rather than per-call, so two callers in a hurry (the settings button
/// and the silent start-up re-registration) resolve to the one
/// registration in flight rather than racing two of them.
Completer<String?>? _pendingToken;

void _listenOnce() {
  if (_listening) return;
  _listening = true;
  _channel.setMethodCallHandler((call) async {
    switch (call.method) {
      case 'remoteToken':
        _pendingToken?.complete(call.arguments as String?);
      case 'remoteTokenError':
        _pendingToken?.complete(null);
    }
    return null;
  });
}

Future<String?> _registerForRemoteToken() async {
  _listenOnce();
  final existing = _pendingToken;
  if (existing != null) return existing.future;

  final completer = Completer<String?>();
  _pendingToken = completer;
  try {
    await _channel.invokeMethod('registerForRemoteNotifications');
  } on PlatformException {
    _pendingToken = null;
    return null;
  }

  // Apple's own answer is normally near-instant. This is only for a
  // device that genuinely never answers — airplane mode on the very
  // first launch, a simulator with no push entitlement — which arrives
  // as silence rather than as `remoteTokenError`.
  final token = await completer.future.timeout(
    const Duration(seconds: 10),
    onTimeout: () => null,
  );
  _pendingToken = null;
  return token;
}

Future<String> _authorizationStatus() async {
  try {
    return await _channel.invokeMethod<String>('authorizationStatus') ??
        'notDetermined';
  } on PlatformException {
    return 'notDetermined';
  }
}

bool get _capable => defaultTargetPlatform == TargetPlatform.iOS;

Future<PushStatus> pushStatus(String vapidPublicKey) async {
  if (!_capable) return PushStatus.unsupported;
  return switch (await _authorizationStatus()) {
    'denied' => PushStatus.denied,
    'notDetermined' => PushStatus.askable,
    _ => PushStatus.on, // authorized, provisional or ephemeral
  };
}

Future<PushSubscriptionInfo?> subscribeToPush(
  String vapidPublicKey, {
  bool ask = false,
}) async {
  if (!_capable) return null;

  var status = await _authorizationStatus();
  if (status == 'notDetermined') {
    if (!ask) return null;
    bool granted;
    try {
      granted =
          await _channel.invokeMethod<bool>('requestAuthorization') ?? false;
    } on PlatformException {
      granted = false;
    }
    if (!granted) return null;
    status = 'authorized';
  }
  if (status == 'denied') return null;

  final token = await _registerForRemoteToken();
  if (token == null) return null;
  return PushSubscriptionInfo(
    endpoint: token,
    platform: 'ios',
    transport: 'apns',
  );
}

/// The token this handset is already registered with, re-read rather
/// than cached: Apple has no call that hands back a stored token, only
/// one that asks again and is told the same value every time
/// authorization is already granted. Used to know what to remove from
/// the register on the way out — see `disablePush` in `providers.dart`.
Future<String?> currentPushEndpoint() async {
  if (!_capable) return null;
  final status = await _authorizationStatus();
  if (status == 'denied' || status == 'notDetermined') return null;
  return _registerForRemoteToken();
}

/// iOS has no call that revokes a device token or withdraws
/// authorization from inside the app. The row this leaves behind is
/// removed by `unregisterDevice`, which `disablePush` in
/// `providers.dart` already calls with the token from
/// [currentPushEndpoint] — that is the half of "turning it off" this
/// platform can actually do.
Future<void> unsubscribeFromPush() async {}
