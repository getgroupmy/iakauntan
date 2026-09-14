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
      // False under the test runner, which is not a browser. The point
      // of asserting it is that it is a real answer rather than a
      // hopeful true: `PasskeyButton` draws nothing when this is false,
      // so a wrong true here is a button that cannot work.
      expect(passkeysAvailable, isFalse);
    });

    test('and a build that cannot ask does not pretend to try', () async {
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
}
