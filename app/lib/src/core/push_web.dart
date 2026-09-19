import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import 'push_types.dart';

/// Web push, from the browser's side.
///
/// The whole of it is four calls — register a worker, ask permission,
/// subscribe, hand the three values to `register_device` — and the
/// reason it is worth a file of its own is that every one of them fails
/// differently and most of the failures are silent.
///
/// The worker is registered at the `/push/` scope rather than the root.
/// `index.html` unregisters root-scoped workers on load, because a stale
/// Flutter worker can pin the application to old code; a push worker
/// caught by that rescue would have its subscription cancelled by the
/// browser and notifications would stop with nothing anywhere saying so.
const _scope = '/push/';
const _script = '/push_sw.js';

/// Whether this browser can do it at all.
///
/// Checked by feature rather than by user agent. Safari can, but only
/// once the app has been installed to the home screen — and what that
/// looks like from here is `PushManager` simply not being there, which
/// is the right answer without needing to know why.
bool get _capable =>
    web.window.has('PushManager') &&
    web.window.has('Notification') &&
    web.window.navigator.has('serviceWorker') &&
    // A service worker needs a secure context. On http://<lan-ip> during
    // development there is none, and `serviceWorker` exists but every
    // call on it rejects.
    web.window.isSecureContext;

Future<PushStatus> pushStatus(String vapidPublicKey) async {
  if (!_capable) return PushStatus.unsupported;
  if (vapidPublicKey.isEmpty) return PushStatus.notConfigured;

  final permission = web.Notification.permission;
  if (permission == 'denied') return PushStatus.denied;
  if (permission != 'granted') return PushStatus.askable;

  // Granted is not the same as subscribed: permission survives a
  // subscription the browser has since dropped, and a person looking at
  // "on" with no subscription is looking at a lie.
  return (await currentPushTokens()).isEmpty
      ? PushStatus.askable
      : PushStatus.on;
}

/// The worker, registered once and reused.
Future<web.ServiceWorkerRegistration?> _registration({
  bool create = true,
}) async {
  try {
    final existing = await web.window.navigator.serviceWorker
        .getRegistration(_scope)
        .toDart;
    if (existing != null) return existing;
    if (!create) return null;

    return await web.window.navigator.serviceWorker
        .register(_script.toJS, web.RegistrationOptions(scope: _scope))
        .toDart;
  } catch (_) {
    // A browser with service workers disabled, or an insecure context
    // that slipped past the check above. Either way there is nothing to
    // register and nothing useful to say.
    return null;
  }
}

/// The endpoint this browser is currently subscribed with.
///
/// A list of at most one, because the two halves of `push.dart` share a
/// signature and an iPhone holds two tokens — see `push_native.dart`.
Future<List<String>> currentPushTokens() async {
  if (!_capable) return const [];
  final registration = await _registration(create: false);
  if (registration == null) return const [];
  final subscription = await registration.pushManager.getSubscription().toDart;
  final endpoint = subscription?.endpoint;
  return endpoint == null ? const [] : [endpoint];
}

/// Subscribe, asking for permission only when told to.
///
/// `ask` is not a convenience. Safari requires the permission prompt to
/// come from a user gesture and refuses it otherwise, and a browser that
/// refuses once will not be asked again — so the app never asks on
/// start-up. It asks when somebody presses the button in Settings, and
/// on every start after that it re-subscribes silently.
Future<List<PushRegistration>> subscribeToPush(
  String vapidPublicKey, {
  bool ask = false,
}) async {
  if (!_capable || vapidPublicKey.isEmpty) return const [];

  var permission = web.Notification.permission;
  if (permission != 'granted') {
    if (!ask || permission == 'denied') return const [];
    permission = (await web.Notification.requestPermission().toDart).toDart;
    if (permission != 'granted') return const [];
  }

  final registration = await _registration();
  if (registration == null) return const [];

  final web.PushSubscription subscription;
  try {
    subscription = await registration.pushManager
        .subscribe(
          web.PushSubscriptionOptionsInit(
            // Required by every browser that implements this, and a
            // promise: every push draws something the person can see.
            // `push_sw.js` keeps it even for a payload it cannot read.
            userVisibleOnly: true,
            applicationServerKey: _decodeKey(vapidPublicKey).toJS,
          ),
        )
        .toDart;
  } catch (_) {
    // The commonest cause is a key that does not match the one an
    // earlier subscription was made with, which browsers refuse rather
    // than replace.
    await unsubscribeFromPush();
    return const [];
  }

  final p256dh = subscription.getKey('p256dh');
  final auth = subscription.getKey('auth');
  if (p256dh == null || auth == null) return const [];

  return [
    PushRegistration(
      token: subscription.endpoint,
      platform: 'web',
      transport: 'web',
      label: 'This browser',
      p256dh: _b64url(p256dh.toDart.asUint8List()),
      auth: _b64url(auth.toDart.asUint8List()),
    ),
  ];
}

Future<void> unsubscribeFromPush() async {
  if (!_capable) return;
  final registration = await _registration(create: false);
  final subscription = await registration?.pushManager.getSubscription().toDart;
  if (subscription != null) await subscription.unsubscribe().toDart;
}

/// The application server key, as bytes.
///
/// Firefox has historically refused a base64url string here even though
/// the specification allows one, so it is decoded rather than passed
/// through.
Uint8List _decodeKey(String base64Url) {
  final normalised = base64Url.replaceAll('-', '+').replaceAll('_', '/');
  return base64.decode(
    normalised.padRight((normalised.length + 3) ~/ 4 * 4, '='),
  );
}

String _b64url(Uint8List bytes) => base64Url.encode(bytes).replaceAll('=', '');
