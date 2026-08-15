/// What a browser hands back when it subscribes to push.
///
/// Three values, not one. The endpoint is the push service's URL for
/// this installation and stands in for a Firebase token; the two keys
/// are what the payload is encrypted to under RFC 8291, so the push
/// service carries ciphertext it cannot read.
class PushSubscriptionInfo {
  const PushSubscriptionInfo({
    required this.endpoint,
    required this.p256dh,
    required this.auth,
  });

  final String endpoint;
  final String p256dh;
  final String auth;
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
