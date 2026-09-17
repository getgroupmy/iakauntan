/// A passkey ceremony that failed for a reason worth saying out loud.
///
/// The platform files answer `null` when somebody dismissed the prompt,
/// because changing your mind is not a fault and a snackbar about it is
/// the app arguing with you. But not every unhappy ending is a
/// dismissal, and the two must not be collapsed.
///
/// On a phone the common one is a domain that is not associated with
/// the app — no `assetlinks.json` on Android, no
/// `apple-app-site-association` on iOS, or one that does not name this
/// build. The system then refuses the ceremony outright, and it looks
/// from the outside exactly like a button that does nothing. That is
/// the worst possible presentation of a build-configuration mistake:
/// silent, on the sign-in screen, for everyone.
///
/// So the mobile implementation throws this instead, and
/// `signInWithPasskey` turns it into a message. The browser has no
/// equivalent — WebAuthn reports a dismissal and a refusal with the
/// same `NotAllowedError`, deliberately, so that a page cannot learn
/// which it was — so nothing on web throws this.
library;

/// Thrown by a platform implementation when the ceremony failed for a
/// stated reason.
class PasskeyFailure implements Exception {
  /// Constructs a failure carrying the sentence to show.
  const PasskeyFailure(this.message);

  /// What to put in front of the person, already in plain language.
  final String message;

  @override
  String toString() => 'PasskeyFailure: $message';
}
