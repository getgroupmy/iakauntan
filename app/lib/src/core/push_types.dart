/// What a platform hands back when it registers this installation for
/// push.
///
/// A browser hands back three values: the endpoint is the push
/// service's URL for this installation and stands in for a device
/// token, and the two keys are what the payload is encrypted to under
/// RFC 8291. iOS hands back one raw APNs token and neither key —
/// `p256dh` and `auth` are a browser's alone, and `register_device`
/// (0143, 0657) refuses a non-web row that carries them. `platform` and
/// `transport` say which of `register_device`'s shapes this is, so
/// `enablePush` in `providers.dart` does not have to hardcode `web` for
/// every caller the way it did before there was a second one.
class PushSubscriptionInfo {
  const PushSubscriptionInfo({
    required this.endpoint,
    this.p256dh,
    this.auth,
    this.platform = 'web',
    this.transport = 'web',
  });

  final String endpoint;
  final String? p256dh;
  final String? auth;

  /// `register_device`'s `p_platform`: `web`, `ios` or `android`.
  final String platform;

  /// `register_device`'s `p_transport` (0657): `web`, `fcm` or `apns`.
  final String transport;
}

/// Why notifications are not on, in words somebody can act on.
///
/// A single "it didn't work" is the wrong answer here: the four reasons
/// below need four different things from the person reading them, and
/// only one of them is worth offering a button for.
enum PushStatus {
  /// This build cannot do it at all — Android, iOS, or a browser too old.
  unsupported,

  /// The browser can, and nobody has been asked yet.
  askable,

  /// Asked and refused. The browser will not ask again; it has to be
  /// changed in site settings, which the app cannot do for them.
  denied,

  /// On.
  on,

  /// The keys are not configured on this deployment, so subscribing
  /// would produce a registration nothing can ever send to.
  notConfigured,
}
