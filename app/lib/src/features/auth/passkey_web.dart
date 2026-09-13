/// WebAuthn in a browser, in the shape GoTrue asks for.
///
/// `auth.passkey.startAuthentication()` hands back an `options` object
/// in the W3C `PublicKeyCredentialRequestOptionsJSON` form, and
/// `verifyAuthentication` wants the assertion back as
/// `AuthenticationResponseJSON`. Between those two the browser has to
/// be asked, and that is all this file does.
///
/// ## Why `js_interop_unsafe` and not `package:web`
///
/// `package:web` 1.1.1 binds `PublicKeyCredential` but not the two
/// static methods that make this tractable —
/// `parseRequestOptionsFromJSON` and `parseCreationOptionsFromJSON` —
/// nor the instance `toJSON()`. Those are what convert between the
/// JSON GoTrue speaks and the ArrayBuffers the browser wants.
///
/// Doing it without them means hand-rolling base64url to ArrayBuffer
/// in both directions over a structure with optional nested fields,
/// which is a lot of code to get subtly wrong in a place where "subtly
/// wrong" means a signature that will not verify. Calling the browser's
/// own converters through `js_interop_unsafe` is the smaller risk, and
/// it is the same approach `captcha_web.dart` and
/// `text_reader_web.dart` already take here.
///
/// ## What happens on a browser too old to have them
///
/// [passkeysUsable] returns false and the button is not drawn. Those
/// methods shipped in Chrome 119, Safari 17.4 and Firefox 119, so this
/// is a genuinely old browser — and one that cannot be supported
/// silently, because a half-working passkey is worse than an absent
/// one: it fails at the moment somebody is trying to get in.
library;

import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:web/web.dart' as web;

/// The browser can be asked. Whether it will succeed is
/// [passkeysUsable].
bool get passkeysAvailable => true;

/// The `PublicKeyCredential` constructor, or null where there is none.
JSObject? get _pkc {
  final o = web.window.getProperty<JSAny?>('PublicKeyCredential'.toJS);
  return o.isA<JSObject>() ? o as JSObject : null;
}

bool _has(JSObject o, String name) => o.getProperty<JSAny?>(name.toJS) != null;

/// Whether this browser can actually complete a passkey ceremony.
///
/// Three questions, and all three have to be yes:
///
///   * `PublicKeyCredential` exists at all — no WebAuthn otherwise;
///   * it carries the JSON converters this file depends on;
///   * a user-verifying platform authenticator is available, which is
///     what "there is a fingerprint reader, a face camera or a device
///     PIN on this machine" comes to.
///
/// The third is asked of the browser rather than assumed, because a
/// desktop with no authenticator is a real and common case, and drawing
/// the button there offers somebody a door with nothing behind it.
Future<bool> passkeysUsable() async {
  final pkc = _pkc;
  if (pkc == null) return false;
  if (!_has(pkc, 'parseRequestOptionsFromJSON')) return false;
  if (!_has(pkc, 'isUserVerifyingPlatformAuthenticatorAvailable')) return false;
  try {
    final r =
        await web
                .PublicKeyCredential.isUserVerifyingPlatformAuthenticatorAvailable()
            .toDart;
    return r.toDart;
  } catch (_) {
    // A browser that throws rather than answering is one this cannot
    // rely on. Same answer as no.
    return false;
  }
}

/// Ask the browser for an assertion, for signing in.
///
/// Returns the `AuthenticationResponseJSON` GoTrue's
/// `verifyAuthentication` wants, or null when the person dismissed the
/// prompt — which is not an error and must not be reported as one.
Future<Map<String, dynamic>?> getPasskeyAssertion(
  Map<String, dynamic> options,
) => _ceremony(options, creating: false);

/// Ask the browser to create a credential, for enrolling one.
///
/// Returns the `RegistrationResponseJSON` `verifyRegistration` wants,
/// or null when the person dismissed the prompt.
Future<Map<String, dynamic>?> createPasskeyCredential(
  Map<String, dynamic> options,
) => _ceremony(options, creating: true);

/// The two ceremonies differ in three names and nothing else.
///
/// One function rather than two near-copies: the conversion in and out
/// is where this can go wrong, and it should go wrong in one place or
/// not at all.
Future<Map<String, dynamic>?> _ceremony(
  Map<String, dynamic> options, {
  required bool creating,
}) async {
  final pkc = _pkc;
  if (pkc == null) return null;

  final parse = creating
      ? 'parseCreationOptionsFromJSON'
      : 'parseRequestOptionsFromJSON';
  if (!_has(pkc, parse)) return null;

  final parsed = pkc.callMethod<JSObject>(
    parse.toJS,
    options.jsify() as JSObject,
  );

  final request = JSObject()..setProperty('publicKey'.toJS, parsed);

  final JSAny? credential;
  try {
    credential = creating
        ? await web.window.navigator.credentials
              .create(request as web.CredentialCreationOptions)
              .toDart
        : await web.window.navigator.credentials
              .get(request as web.CredentialRequestOptions)
              .toDart;
  } catch (_) {
    // `NotAllowedError` is what a dismissed prompt and a timeout both
    // raise, and neither is a fault worth putting in front of somebody
    // who simply changed their mind. The caller says "that did not
    // work" once, for every reason.
    return null;
  }

  if (credential == null || !credential.isA<JSObject>()) return null;
  final obj = credential as JSObject;
  if (!_has(obj, 'toJSON')) return null;

  final json = obj.callMethod<JSObject>('toJSON'.toJS);
  final out = json.dartify();
  return out is Map ? Map<String, dynamic>.from(out) : null;
}
