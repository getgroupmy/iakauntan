/// WebAuthn on a phone, in the shape GoTrue asks for.
///
/// The browser half of this is three lines of interop because the
/// browser owns the ceremony. A phone does not: Android reaches
/// passkeys through Credential Manager and iOS through
/// `ASAuthorizationController`, and both want typed platform calls
/// rather than a JSON blob. The `passkeys` plugin is the bridge, and
/// the only reason this file is short is that its request and response
/// types already speak the same JSON GoTrue does — `fromJson` takes a
/// `PublicKeyCredentialRequestOptionsJSON` verbatim and `toJson()`
/// emits an `AuthenticationResponseJSON` verbatim. No base64url is
/// hand-rolled here, in either direction, which is the whole reason
/// the plugin is worth twelve dependencies.
///
/// ## What was checked before adding those twelve
///
/// They are `passkeys` and its four platform implementations, plus
/// `device_info_plus`, `package_info_plus`, `ua_client_hints`,
/// `win32_registry` and `passkeys_doctor`, with their two interface
/// packages. Three findings, because an accounting product does not
/// take a dependency on trust:
///
///   * No package in the set contacts a third party. The only network
///     calls in any of them are `passkeys_doctor` fetching
///     `https://<rpid>/.well-known/assetlinks.json` or
///     `apple-app-site-association` — this application's own domain,
///     unauthenticated, the same two files any phone fetches anyway.
///   * `passkeys_doctor` runs only when `debugMode` is set on the
///     authenticator. It is [kDebugMode] here, so a release build makes
///     no such call and a release sign-in is one round trip, not two.
///   * `ua_client_hints` reads the device model, OS version and app
///     build and sends nothing anywhere. It is pulled in under the
///     doctor and is inert in release for the same reason.
///
/// ## Desktop is not mobile
///
/// This file is selected by `dart.library.io`, which is every build
/// that is not the web — Linux, Windows and macOS included, and the
/// Dart VM that runs the tests. [passkeysAvailable] is therefore a
/// runtime question and not a compile-time one: it answers true on
/// Android and iOS and false everywhere else, so a `flutter test` run
/// and a Linux desktop build both take the same path a browser without
/// WebAuthn takes, which is to draw no button at all.
library;

import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:passkeys/authenticator.dart';
import 'package:passkeys/types.dart';

import 'passkey_failure.dart';

/// The two platforms this plugin can actually reach a passkey on.
///
/// `passkeys_windows` and the macOS half of `passkeys_darwin` exist and
/// are not claimed: neither is a target this application ships, and a
/// path nobody runs is a path nobody has tested.
bool get passkeysAvailable => Platform.isAndroid || Platform.isIOS;

/// One authenticator for the process.
///
/// It holds an in-flight operation and cancels it before starting the
/// next, which is only correct if there is one of them. Two would race
/// to cancel each other.
final PasskeyAuthenticator _authenticator = PasskeyAuthenticator(
  debugMode: kDebugMode,
);

/// Whether this device can actually complete a passkey ceremony.
///
/// Two questions on Android — is there passkey support, and is there a
/// user-verifying authenticator, which is "a fingerprint, a face or a
/// screen lock" — and one on iOS, where the platform answers for the
/// screen lock itself and `hasBiometrics` is deliberately not required:
/// a device passcode verifies a user perfectly well and refusing
/// somebody who has not enrolled a fingerprint would be inventing a
/// rule Apple does not have.
Future<bool> passkeysUsable() async {
  if (!passkeysAvailable) return false;
  try {
    final availability = _authenticator.getAvailability();
    if (Platform.isAndroid) {
      final android = await availability.android();
      return android.hasPasskeySupport &&
          (android.isUserVerifyingPlatformAuthenticatorAvailable ?? false);
    }
    final ios = await availability.iOS();
    return ios.hasPasskeySupport;
  } catch (_) {
    // A platform that throws rather than answering is one this cannot
    // rely on, and the button is absent rather than broken. Same
    // answer as no.
    return false;
  }
}

/// Ask the device for an assertion, for signing in.
///
/// Returns the `AuthenticationResponseJSON` GoTrue's
/// `verifyAuthentication` wants, or null when the person dismissed the
/// prompt or had nothing to offer it.
///
/// `preferImmediatelyAvailableCredentials` is false on purpose. True
/// means "only offer what is already on this handset", which is the
/// right default for a prompt that appears unbidden; this one appears
/// because somebody pressed a button that says passkey, and the flows
/// the flag suppresses — a hardware key over USB or NFC, a passkey
/// living on another device — are exactly what that person may be
/// reaching for. The cost is that a handset with no passkey shows a
/// chooser rather than failing instantly, which is the better failure.
Future<Map<String, dynamic>?> getPasskeyAssertion(
  Map<String, dynamic> options,
) async {
  if (!passkeysAvailable) return null;
  try {
    final response = await _authenticator.authenticate(
      AuthenticateRequestType.fromJson(
        pluginOptions(options, creating: false),
        preferImmediatelyAvailableCredentials: false,
      ),
    );
    return response.toJson();
  } on PasskeyAuthCancelledException {
    return null;
  } on NoCredentialsAvailableException {
    return null;
  } on AuthenticatorException catch (e) {
    throw PasskeyFailure(_explain(e));
  }
}

/// Ask the device to create a credential, for enrolling one.
///
/// Returns the `RegistrationResponseJSON` `verifyRegistration` wants,
/// or null when the person dismissed the prompt.
///
/// GoTrue sends `user.id` base64url without padding and the plugin
/// documents that field as padded; its validator allows both, so the
/// options go through untouched. Said here because the next person to
/// read that doc comment will wonder.
Future<Map<String, dynamic>?> createPasskeyCredential(
  Map<String, dynamic> options,
) async {
  if (!passkeysAvailable) return null;
  try {
    final response = await _authenticator.register(
      RegisterRequestType.fromJson(pluginOptions(options, creating: true)),
    );
    return response.toJson();
  } on PasskeyAuthCancelledException {
    return null;
  } on ExcludeCredentialsCanNotBeRegisteredException {
    // This device already holds a passkey for this account. Enrolling
    // a second one is what was refused, and the person has what they
    // came for.
    return null;
  } on AuthenticatorException catch (e) {
    throw PasskeyFailure(_explain(e));
  }
}

/// GoTrue's options, in the form the plugin's generated codecs accept.
///
/// Public, and named rather than folded into the two call sites,
/// because it is the one place in this file where the JSON is touched
/// at all. Everything else forwards what GoTrue sent verbatim; if a
/// passkey signature ever fails to verify on a phone, this function is
/// where to look first, and a seam nobody can call is a seam nobody can
/// test.
Map<String, dynamic> pluginOptions(
  Map<String, dynamic> options, {
  required bool creating,
}) {
  final filled = _fillTransports(
    options,
    creating ? 'excludeCredentials' : 'allowCredentials',
  );
  return creating ? _fillUserNames(filled) : filled;
}

/// Give every credential descriptor a `transports` list.
///
/// WebAuthn marks `transports` optional on a credential descriptor and
/// GoTrue leaves it out; the plugin's `CredentialType.fromJson` is
/// generated code that casts the field with `as List<dynamic>`. A
/// descriptor without it therefore throws a `TypeError` — not an
/// `AuthenticatorException`, so nothing below would catch it, and the
/// sign-in button would blow up rather than fail.
///
/// The empty list means the same thing to both platforms as an absent
/// one: no hint about how to reach this credential. Filling it in is
/// the whole fix, and it happens on the way in so that the options this
/// file forwards are the options GoTrue sent plus a field it is allowed
/// to omit.
Map<String, dynamic> _fillTransports(Map<String, dynamic> options, String key) {
  final descriptors = options[key];
  if (descriptors is! List) return options;
  return {
    ...options,
    key: [
      for (final descriptor in descriptors)
        if (descriptor is Map)
          () {
            final copy = Map<String, dynamic>.from(descriptor);
            if (copy['transports'] is! List) {
              copy['transports'] = const <String>[];
            }
            return copy;
          }()
        else
          descriptor,
    ],
  };
}

/// Give the user a `name` and a `displayName`.
///
/// Same shape of problem as [_fillTransports], one level further in:
/// `UserType.fromJson` casts both with `as String`. GoTrue sends both,
/// so this is a guard rather than a fix — but the failure it guards
/// against is a crash on the enrolment path, and the fallback (the
/// display name is the name, the name is the display name, and an
/// account with neither is identified by nothing) is what a person
/// would write down anyway.
Map<String, dynamic> _fillUserNames(Map<String, dynamic> options) {
  final user = options['user'];
  if (user is! Map) return options;
  final copy = Map<String, dynamic>.from(user);
  final name = copy['name'] as String?;
  final displayName = copy['displayName'] as String?;
  copy['name'] = name ?? displayName ?? '';
  copy['displayName'] = displayName ?? name ?? '';
  return {...options, 'user': copy};
}

/// Turn a plugin exception into a sentence somebody can act on.
///
/// The distinction that matters is who can fix it. A domain that is not
/// associated, or a device that cannot do this at all, is not something
/// the person holding the phone can do anything about, and telling them
/// to "try again" wastes their time; the honest version names the wall.
/// Anything unrecognised keeps the plugin's own words rather than being
/// flattened into "something went wrong", because a message nobody can
/// search for is a message that costs a support call.
String _explain(AuthenticatorException e) => switch (e) {
  DomainNotAssociatedException() =>
    'This app is not set up for passkeys on this system yet.',
  DeviceNotSupportedException() =>
    'This device cannot use passkeys. Sign in with a password instead.',
  PasskeyUnsupportedException() =>
    'This device cannot use passkeys. Sign in with a password instead.',
  MissingGoogleSignInException() || SyncAccountNotAvailableException() =>
    'Passkeys need a Google account signed in on this device.',
  TimeoutException() => 'The passkey prompt timed out.',
  MalformedBase64Url() => 'The sign-in challenge was not readable.',
  _ => e.toString().isEmpty ? 'That did not work.' : e.toString(),
};
