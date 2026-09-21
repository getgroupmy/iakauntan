/// One row on the push register: a token and the service it belongs to.
///
/// One device does not always mean one of these. A browser hands back
/// exactly one — an endpoint and the two keys the payload is encrypted
/// to under RFC 8291, so the push service carries ciphertext it cannot
/// read. A directly-reached iPhone hands back TWO, from two different
/// Apple services: the alert token and the PushKit token. They are not
/// interchangeable and sending one to the other service fails, in the
/// PushKit direction badly enough to get the app killed. See 0658.
class PushRegistration {
  const PushRegistration({
    required this.token,
    required this.platform,
    required this.transport,
    this.deviceId,
    this.label,
    this.p256dh,
    this.auth,
  });

  /// The browser's endpoint, or the device token, verbatim.
  final String token;

  /// `web`, `ios` or `android`. What `register_device` calls a platform.
  final String platform;

  /// `web`, `fcm`, `apns` or `apns_voip`.
  final String transport;

  /// Which handset this came from, where the platform can say.
  ///
  /// Both of an iPhone's tokens carry the same one, and that is the
  /// only thing that lets the sender ring a phone through CallKit
  /// without also sending it a banner about the same call. Null for a
  /// browser, which has one registration anyway.
  final String? deviceId;

  /// What to call it in a list of somebody's devices.
  final String? label;

  /// Browsers only, and both required there: 0143 refuses a web row
  /// without them and a token registration with them.
  final String? p256dh;
  final String? auth;
}

/// Why notifications are not on, in words somebody can act on.
///
/// A single "it didn't work" is the wrong answer here: the five reasons
/// below need different things from the person reading them, and only
/// one of them is worth offering a button for.
enum PushStatus {
  /// This build cannot do it at all — Android, a desktop, or a browser
  /// too old.
  unsupported,

  /// The device can, and nobody has been asked yet.
  askable,

  /// Asked and refused. Neither a browser nor iOS will ask again; it
  /// has to be changed in settings, which the app cannot do for them.
  denied,

  /// On.
  on,

  /// The keys are not configured on this deployment, so subscribing
  /// would produce a registration nothing can ever send to.
  notConfigured,
}
