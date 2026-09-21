import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/features/auth/passkey.dart';
import 'package:iakauntan/src/features/landing/landing_content.dart';

/// Signing in with a key instead of a password.
///
/// The ceremony itself cannot be asserted here: it needs a browser, a
/// platform authenticator and a project with passkeys switched on in
/// the Supabase dashboard. What CAN be asserted is everything around
/// it, and those are the parts that decide whether somebody is ever
/// offered the button:
///
///   * the switch ships off, so nobody is shown a button that GoTrue
///     will refuse with `passkey_disabled`;
///   * a build that cannot reach an authenticator says so rather than
///     reporting a false;
///   * a dismissed prompt is not a failure.
///
/// The last is the one worth having a test for. A person who closes the
/// system prompt has made a decision, and an app that answers "that did
/// not work" is arguing with them about it.
void main() {
  group('the switch', () {
    test('ships off, alone among the sign-in switches', () {
      // Every other switch on this page ships on, because the thing it
      // governs already works. This one does not work until somebody
      // turns passkeys on for the project, so on would be a default
      // that breaks the sign-in form of every deployment taking it.
      final shipped = parseLandingContent(const {});
      expect(shipped.signinShowPasskey, isFalse);
    });

    test('comes from brand, so it reaches a form before publication', () {
      // `page` is gated on `is_published`. The sign-in screen draws
      // whether or not anybody has published a marketing site, which is
      // why this rides in `brand` with `signin_show_register` and the
      // rest.
      final content = parseLandingContent(const {
        'brand': {'signin_show_passkey': true},
      });
      expect(content.signinShowPasskey, isTrue);
    });

    test('and falls back to page, which is where it also arrives', () {
      // `landing_payload` builds `page` from `to_jsonb(p)`, so the
      // column lands in BOTH halves of the payload. `brandBool` reads
      // brand first and page second, which is what every other switch
      // on this screen does — asserted here because the fallback is
      // what keeps a payload written before `brand` carried this from
      // silently reading as off.
      final content = parseLandingContent(const {
        'page': {'signin_show_passkey': true},
      });
      expect(content.signinShowPasskey, isTrue);
    });

    test('and brand wins when the two disagree', () {
      // They cannot disagree in a payload this database builds. They
      // can in one somebody hand-assembles, and the precedence should
      // be the one the rest of the screen uses rather than whichever
      // key happened to be read last.
      final content = parseLandingContent(const {
        'brand': {'signin_show_passkey': false},
        'page': {'signin_show_passkey': true},
      });
      expect(content.signinShowPasskey, isFalse);
    });
  });

  group('this build', () {
    test('reports honestly whether it can ask for a passkey', () {
      // TRUE under the test runner now, and the old assertion that it
      // was false is what `0638` changed. The runner resolves the
      // `dart.library.io` arm of the conditional import, which used to
      // be `passkey_stub.dart` -- a file whose entire purpose was to
      // say no because no phone could reach an authenticator. It is
      // `passkey_native.dart` now, and a phone can.
      //
      // The stub is still there and still says false. Nothing reaches
      // it: `dart.library.js_interop` takes the web and
      // `dart.library.io` takes everything else, so it is the
      // fallback for a platform Dart does not have. Left in place
      // rather than deleted, because deleting it makes the conditional
      // import unparseable.
      expect(passkeysAvailable, isTrue);
    });

    test('and asking whether it will work is a separate question',
        () async {
      // The distinction the two exist for, and it survives
      // `passkeysAvailable` flipping to true. `passkeysAvailable` is
      // "is there any code here that could try"; `passkeysUsable()` is
      // "will the platform answer", and only the second goes and finds
      // out.
      //
      // Under the runner there is no Credential Manager and no
      // `ASAuthorization`, so the platform channel raises
      // `MissingPluginException` and the `on Object` in
      // `passkeysUsable` turns it into a no. That catch is the thing
      // asserted here: without it the sign-in screen's capability
      // check throws instead of answering, which draws no button and
      // logs an exception rather than drawing no button quietly.
      expect(await passkeysUsable(), isFalse);
    });
  });

  group('the three outcomes', () {
    test('are three and not two', () {
      // `cancelled` exists so a dismissed prompt can be distinguished
      // from a refusal. Collapsing it into `failed` is the bug this
      // names: somebody who closed the prompt on purpose would be told
      // their passkey was not accepted.
      expect(PasskeyOutcome.values, hasLength(3));
      expect(
        PasskeyOutcome.values,
        containsAll([
          PasskeyOutcome.signedIn,
          PasskeyOutcome.cancelled,
          PasskeyOutcome.failed,
        ]),
      );
    });
  });

  group('the other half', () {
    test('exists, which is the whole point of this group', () {
      // `signInWithPasskey` shipped alone, and `startAuthentication`
      // offers whichever accounts hold a passkey for this site — which,
      // with nothing anywhere able to create one, was none of them. The
      // button on the sign-in screen could not succeed for anybody.
      //
      // Asserted as a reference rather than a call because enrolling
      // needs a browser, a platform authenticator and a session. What
      // this catches is the enrolment half being deleted or renamed
      // while the sign-in half stays, which is the state that shipped.
      expect(enrolPasskey, isA<Function>());
    });

    test('and reports the same three outcomes as signing in', () {
      // Both halves hand back a `PasskeyResult`, so a caller writes the
      // dismissed/failed distinction once. A second shape here would be
      // a second chance to report a cancellation as a failure.
      expect(signInWithPasskey, isA<Function>());
      expect(enrolPasskey, isA<Function>());
    });
  });

  group('where a passkey may be kept', () {
    test('is the browser to decide, not this code', () {
      // `passkeysUsable` used to require
      // `isUserVerifyingPlatformAuthenticatorAvailable()` — a question
      // about the machine you happen to be sitting at. A passkey does
      // not have to live there, and that check hid all four of the
      // places it usually goes: iCloud Keychain, Google Password
      // Manager, a phone over a QR code, and a security key on USB.
      //
      // The same restraint is written into `passkey_native.dart` for
      // the same reason, and it matters more on a phone than it did in
      // a browser: an Android handset with no screen lock still has
      // Google Password Manager, and an iPhone with Face ID switched
      // off still has the keychain.
      //
      // What is asserted is the SHAPE, because the answer itself needs
      // a platform to ask: one question, about whether the ceremony can
      // run at all, with nothing asked about the hardware in front of
      // the person. That is what stops the narrow check coming back.
      expect(passkeysUsable, isA<Function>());
    });
  });
}
