/// Signing in with a passkey.
///
/// GoTrue does the hard half. `auth.passkey.startAuthentication()`
/// returns a challenge and the options the browser needs;
/// `verifyAuthentication()` takes the assertion back and returns a real
/// session, saves it, and fires `AuthChangeEvent.signedIn` — the same
/// ending `signInWithPassword` has. Nothing here signs a token and no
/// secret leaves the Supabase dashboard.
///
/// ## Three things have to be true before the button appears
///
///   1. `signin_show_passkey` is on in the platform console. It ships
///      OFF, because of (2).
///   2. Passkeys are switched on for the project in the Supabase
///      dashboard. Until they are, GoTrue answers `passkey_disabled`
///      to every call, so a button drawn before that fails for
///      everybody who presses it.
///   3. This build and this browser can actually run the ceremony —
///      `passkeysUsable()`, which asks whether there is a
///      user-verifying authenticator on the machine.
///
/// The first is a decision, the second is a dashboard switch, and the
/// third is a fact about the device. All three are needed, and the
/// button is absent rather than disabled when any is missing: a
/// disabled control invites somebody to work out why, and there is
/// nothing they can do about any of these.
///
/// ## No identifier is typed
///
/// `startAuthentication` takes no email. The browser offers whichever
/// accounts have a passkey for this site and the person picks one, so
/// there is nothing to type and nothing to remember. That is the whole
/// point of it, and it is also why this cannot leak which addresses
/// exist: the question is never asked.
library;

import 'package:supabase_flutter/supabase_flutter.dart';

import 'passkey_failure.dart';
import 'passkey_stub.dart' if (dart.library.js_interop) 'passkey_web.dart';

export 'passkey_failure.dart' show PasskeyFailure;
export 'passkey_stub.dart'
    if (dart.library.js_interop) 'passkey_web.dart'
    show passkeysAvailable, passkeysUsable;

/// What came of trying to sign in with a passkey.
///
/// Three outcomes and not two, because "the person changed their mind"
/// is not a failure and must not be reported as one. A snackbar saying
/// "that did not work" after somebody deliberately closed the prompt is
/// the app arguing with them.
enum PasskeyOutcome { signedIn, cancelled, failed }

/// The result, with the message to show when there is one.
typedef PasskeyResult = ({PasskeyOutcome outcome, String? message});

/// Enrol a passkey on this device, start to finish.
///
/// The other half of [signInWithPasskey], and without it that button is
/// a door with nothing behind it: `startAuthentication` offers whichever
/// accounts hold a passkey for this site, and until somebody has saved
/// one, that is none of them. Shipping the sign-in half alone meant a
/// button nobody could ever succeed at.
///
/// Needs a signed-in session, which is the whole shape of it: you prove
/// who you are with a password once, and then never again on this
/// device. GoTrue refuses at `aal1` for a user with verified MFA
/// factors, so somebody with two-factor on has to be at `aal2` first.
Future<PasskeyResult> enrolPasskey(GoTrueClient auth) async {
  if (!passkeysAvailable) {
    return (outcome: PasskeyOutcome.failed, message: null);
  }

  final Map<String, dynamic> options;
  final String challengeId;
  try {
    final start = await auth.passkey.startRegistration();
    options = Map<String, dynamic>.from(start.options);
    challengeId = start.challengeId;
  } on AuthException catch (e) {
    return (
      outcome: PasskeyOutcome.failed,
      message: e.code == 'passkey_disabled'
          ? 'Passkeys are not switched on for this system yet.'
          : e.message,
    );
  }

  final credential = await createPasskeyCredential(options);
  if (credential == null) {
    return (outcome: PasskeyOutcome.cancelled, message: null);
  }

  try {
    await auth.passkey.verifyRegistration(
      challengeId: challengeId,
      credential: credential,
    );
    return (outcome: PasskeyOutcome.signedIn, message: null);
  } on AuthException catch (e) {
    return (outcome: PasskeyOutcome.failed, message: e.message);
  }
}

/// Sign in with a passkey, start to finish.
///
/// [captchaToken] rides along when Turnstile is configured, the same
/// way it does on every other way in — GoTrue verifies it against the
/// secret in the dashboard, and a project with the protection on
/// refuses a call without one.
Future<PasskeyResult> signInWithPasskey(
  GoTrueClient auth, {
  String? captchaToken,
}) async {
  if (!passkeysAvailable) {
    return (outcome: PasskeyOutcome.failed, message: null);
  }

  final Map<String, dynamic> options;
  final String challengeId;
  try {
    final start = await auth.passkey.startAuthentication(
      captchaToken: captchaToken,
    );
    options = Map<String, dynamic>.from(start.options);
    challengeId = start.challengeId;
  } on AuthException catch (e) {
    // The one worth naming. Everything else GoTrue can say here is
    // about this attempt; this one is about the project, and the
    // person pressing the button cannot fix it.
    return (
      outcome: PasskeyOutcome.failed,
      message: e.code == 'passkey_disabled'
          ? 'Passkeys are not switched on for this system yet.'
          : e.message,
    );
  }

  final Map<String, dynamic>? assertion;
  try {
    assertion = await getPasskeyAssertion(options);
  } on PasskeyFailure catch (e) {
    // The platform refused for a reason it was willing to state. Web
    // never does this; a phone does, and the commonest one is a build
    // whose domain is not associated, which is otherwise a button that
    // silently does nothing.
    return (outcome: PasskeyOutcome.failed, message: e.message);
  }
  if (assertion == null) {
    return (outcome: PasskeyOutcome.cancelled, message: null);
  }

  try {
    await auth.passkey.verifyAuthentication(
      challengeId: challengeId,
      credential: assertion,
    );
    return (outcome: PasskeyOutcome.signedIn, message: null);
  } on AuthException catch (e) {
    return (outcome: PasskeyOutcome.failed, message: e.message);
  }
}
