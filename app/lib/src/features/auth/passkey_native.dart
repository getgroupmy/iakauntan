/// WebAuthn on a phone, in the shape GoTrue asks for.
///
/// The same contract `passkey_web.dart` implements, over Corbado's
/// `passkeys` plugin instead of the browser: Android's Credential
/// Manager and iOS's `ASAuthorization`. Both of those speak the same
/// W3C structures GoTrue does, so most of this file is a conversion
/// and the interesting part is which failures are said out loud.
///
/// ## What GoTrue hands over and wants back
///
/// `startAuthentication()` returns `options` as
/// `PublicKeyCredentialRequestOptionsJSON`, and `verifyAuthentication`
/// wants `AuthenticationResponseJSON` back. The plugin's own
/// `AuthenticateRequestType.fromJson` and
/// `AuthenticateResponseType.toJson` are exactly those two shapes, so
/// no base64url is decoded here and nothing is reassembled by hand.
/// That matters: hand-rolling the conversion is a lot of code to get
/// subtly wrong in a place where "subtly wrong" means a signature that
/// will not verify, days after the mistake was made.
///
/// Registration is the same story with `RegisterRequestType` and
/// `RegisterResponseType`.
///
/// ## The one thing this does that the web cannot
///
/// It tells somebody when the ceremony was refused rather than
/// dismissed.
///
/// A browser reports both as `NotAllowedError`, deliberately, so a page
/// cannot learn which it was. A phone does not: the plugin turns the
/// platform's own refusals into typed exceptions, and the commonest by
/// a wide margin is a domain that is not associated with the build —
/// no `assetlinks.json` on Android, no `apple-app-site-association` on
/// iOS, or one that does not name this signing certificate.
///
/// From the outside that is a button that does nothing at all. It is
/// the worst possible presentation of a build-configuration mistake:
/// silent, on the sign-in screen, for every single user, and
/// indistinguishable from the app being broken. So it throws
/// [PasskeyFailure] with a sentence, and `signInWithPasskey` puts it on
/// the screen. `docs/passkeys.md` is the list of what to go and fix.
///
/// ## Changing your mind is not a failure
///
/// `PasskeyAuthCancelledException` returns null, like the web's
/// swallowed `NotAllowedError`. A snackbar after somebody deliberately
/// closed the sheet is the app arguing with them.
library;

import 'package:flutter/foundation.dart';
import 'package:passkeys/authenticator.dart';
import 'package:passkeys/exceptions.dart';
import 'package:passkeys_platform_interface/passkeys_platform_interface.dart';
import 'package:passkeys_platform_interface/types/types.dart';

import 'passkey_failure.dart';

/// The plugin is here, so the ceremony can at least be attempted.
///
/// True on every platform this file is compiled for — which is Android
/// and iOS only, because `passkey.dart`'s conditional import reaches it
/// on `dart.library.io` and the switches in `core/surface.dart` draw no
/// button on desktop. Whether it will SUCCEED is [passkeysUsable].
bool get passkeysAvailable => true;

/// One authenticator, kept, because it holds the cancellation state.
///
/// `PasskeyAuthenticator` cancels any operation still in flight before
/// starting a new one, and it can only do that for operations it
/// started. A fresh instance per call would leave the previous sheet
/// up on Android and the second ceremony would be refused by the
/// system rather than by anybody's choice.
///
/// `debugMode` is [kDebugMode], which is what runs Corbado's doctor:
/// in a debug build it fetches `assetlinks.json` and
/// `apple-app-site-association` and prints what is wrong with them.
/// That is the fastest route to the diagnosis this file's exceptions
/// can only name. A release build makes no such call, which matters —
/// it is a network request to our own domain on every sign-in.
final _authenticator = PasskeyAuthenticator(debugMode: kDebugMode);

/// Whether this device can actually complete a passkey ceremony.
///
/// Asks the platform whether it supports passkeys at all, and nothing
/// else. In particular it does NOT require a fingerprint reader or a
/// face camera to be present and enrolled.
///
/// That restraint is `docs/passkeys.md`'s hardest-won paragraph, from
/// the web side: requiring a user-verifying platform authenticator hid
/// the button from everybody whose passkey lives somewhere other than
/// the machine in front of them — iCloud Keychain, Google Password
/// Manager, another phone by QR, a security key on NFC. The same is
/// true here. An Android handset with no screen lock can still be
/// offered a passkey held in Google Password Manager once one is set,
/// and an iPhone with Face ID switched off still has the keychain.
///
/// The cost of the looser test is a sheet somebody can dismiss on a
/// device with genuinely nothing available, which [getPasskeyAssertion]
/// reports as a cancellation rather than as a fault. That is a much
/// smaller harm than hiding the feature.
///
Future<bool> passkeysUsable() async {
  try {
    // `PasskeysPlatform.instance` rather than the authenticator's own
    // `getAvailability()`, which hands back a wrapper whose
    // `.android()` and `.iOS()` are the SAME platform call with a cast
    // bolted on:
    //
    //     Future<AvailabilityTypeAndroid> android() =>
    //         _platform.getAvailability() as Future<AvailabilityTypeAndroid>;
    //
    // So a caller has to know which platform it is on before it can
    // ask, and guessing wrong is a cast failure rather than an answer.
    // `AvailabilityType` is a sealed base and carries
    // `hasPasskeySupport` on every variant, which is the whole of what
    // this needs.
    final availability = await PasskeysPlatform.instance.getAvailability();
    return availability.hasPasskeySupport;
  } on Object {
    // A platform that will not answer is a no. A build too old for the
    // API, an Android without Play Services -- the question cannot be
    // answered, and a button drawn on a guess fails at the moment
    // somebody is trying to get in.
    return false;
  }
}

/// Ask the platform for an assertion, for signing in.
///
/// Returns the `AuthenticationResponseJSON` GoTrue's
/// `verifyAuthentication` wants, null when somebody dismissed the
/// sheet, and throws [PasskeyFailure] when the platform refused for a
/// reason worth repeating.
Future<Map<String, dynamic>?> getPasskeyAssertion(
  Map<String, dynamic> options,
) async {
  final AuthenticateRequestType request;
  try {
    request = AuthenticateRequestType.fromJson(options);
  } on Object {
    // Options that will not parse are a server that changed shape, not
    // anything the person pressing the button did. Said plainly rather
    // than as a stack trace on the sign-in screen.
    throw const PasskeyFailure(_unreadable);
  }

  try {
    return (await _authenticator.authenticate(request)).toJson();
  } on PasskeyAuthCancelledException {
    return null;
  } on Object catch (e) {
    throw PasskeyFailure(_sentenceFor(e));
  }
}

/// Ask the platform to create a credential, for enrolling one.
///
/// Returns the `RegistrationResponseJSON` `verifyRegistration` wants,
/// or null when somebody dismissed the sheet.
Future<Map<String, dynamic>?> createPasskeyCredential(
  Map<String, dynamic> options,
) async {
  final RegisterRequestType request;
  try {
    request = RegisterRequestType.fromJson(options);
  } on Object {
    throw const PasskeyFailure(_unreadable);
  }

  try {
    return (await _authenticator.register(request)).toJson();
  } on PasskeyAuthCancelledException {
    return null;
  } on Object catch (e) {
    throw PasskeyFailure(_sentenceFor(e));
  }
}

/// What to put in front of somebody when the platform refused.
///
/// Split out and kept pure so it can be tested without a phone, which
/// is the only part of this file that can be. Every branch of it is
/// something that has to be fixed by somebody other than the person
/// reading it, so every branch says so.
@visibleForTesting
String passkeySentenceFor(Object error) => _sentenceFor(error);

String _sentenceFor(Object error) => switch (error) {
  // The big one, and the reason `PasskeyFailure` exists at all. No
  // `assetlinks.json`, no `apple-app-site-association`, or one that
  // does not name this build's signing certificate. Presents as a
  // button that does nothing.
  //
  // The commonest shape of it is an `assetlinks.json` listing only the
  // upload key: it then works on the developer's handset and on no
  // device that installed from Play, because Play re-signs with its
  // own certificate.
  DomainNotAssociatedException() =>
    'This app is not set up for passkeys on this system yet. It is a '
        'setting on the site rather than anything you have done — '
        'please tell whoever runs it, and sign in with your password '
        'for now.',

  // Nobody has saved one for this site on this device. Not a fault,
  // and the answer is a sentence rather than silence: the button is
  // drawn for everybody, and somebody who has never enrolled cannot
  // tell an empty keychain from a broken app.
  NoCredentialsAvailableException() =>
    'There is no passkey saved on this device for this account. Sign '
        'in with your password, then save one from Settings — after '
        'that this button will work here.',

  // Android without a Google account signed in, or with passkey sync
  // switched off. Both are fixable by the person holding the phone,
  // which makes them the only two worth giving instructions for.
  MissingGoogleSignInException() =>
    'Android saves passkeys to your Google account, and there is none '
        'signed in on this device. Add one in Settings, or sign in '
        'with your password.',
  SyncAccountNotAvailableException() =>
    'Android cannot reach the account it saves passkeys to. Check that '
        'Google Password Manager is switched on for this device, or '
        'sign in with your password.',

  // The device or the OS cannot do this at all. `passkeysUsable()` is
  // supposed to have caught this and drawn no button; if it did not,
  // saying so beats a refusal with no explanation.
  DeviceNotSupportedException() || PasskeyUnsupportedException() =>
    'This device cannot use passkeys. Sign in with your password.',

  // The sheet was up and nothing happened. Worth its own sentence
  // because the next thing to do is simply to press it again, which
  // is not obvious from a generic failure.
  TimeoutException() =>
    'The passkey prompt timed out. Try again, or sign in with your '
        'password.',

  // A challenge or credential id that is not base64url. The server
  // sent it, so this is ours to fix and not theirs.
  MalformedBase64Url() => _unreadable,

  // Everything else the platform can raise, including the plugin's
  // `UnhandledAuthenticatorException`. Not silent, and not a stack
  // trace either.
  _ =>
    'The passkey could not be used on this device. Sign in with your '
        'password instead.',
};

const _unreadable =
    'The security check could not be set up, because this system sent '
    'something this app could not read. It is a fault on the site '
    'rather than anything you have done — please tell whoever runs it, '
    'and sign in with your password for now.';
