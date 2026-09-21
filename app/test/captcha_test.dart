import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/features/auth/captcha.dart';

/// The security check on the four forms nobody is signed in for.
///
/// Supabase Auth does the verifying — the SECRET is in the dashboard —
/// and what the app owes it is a widget and a token. What is asserted
/// here is the part that decides whether anything is drawn at all,
/// because getting it wrong in either direction is a form nobody can
/// submit.
void main() {
  /// Which failure it was.
  ///
  /// `web/captcha.js` distinguishes four -- no site key, Cloudflare's
  /// script not fetched, the challenge refused, the render throwing --
  /// and the app printed ONE sentence for all four and threw the reason
  /// away. So a report of "the security check will not load" could not
  /// be told from any other, and the only way to find out which was to
  /// guess and ship a build. Twice.
  group('what the broken message says', () {
    test('an unknown reason is still the plain sentence', () {
      expect(captchaBrokenBecause(null), captchaBroken);
      expect(captchaBrokenBecause(''), captchaBroken);
      expect(captchaBrokenBecause('   '), captchaBroken);
    });

    test('and every reason the page can send adds its own line', () {
      // The four in `captcha.js`, plus the one the app raises itself
      // when there is no webview to draw in.
      for (final why in const [
        'no site key',
        'script blocked',
        'challenge error',
        'render threw',
        'no webview',
      ]) {
        final said = captchaBrokenBecause(why);
        expect(said.startsWith(captchaBroken), isTrue, reason: why);
        expect(said.length, greaterThan(captchaBroken.length), reason: why);
      }
    });

    test('and the four are four different sentences', () {
      // The whole point. If two of them read the same, the message has
      // not told anybody anything they did not already know.
      final said = {
        for (final why in const [
          'no site key',
          'script blocked',
          'challenge error',
          'render threw',
          'no webview',
        ])
          captchaBrokenBecause(why),
      };
      expect(said.length, 5);
    });

    test('a reason nobody taught it about is printed rather than lost', () {
      // A new reason invented in the page must not become invisible
      // here, which is exactly the failure this is fixing.
      final said = captchaBrokenBecause('something new');
      expect(said, contains('something new'));
    });

    test('and the webview error code survives into the sentence', () {
      // The page never ran in that case, so its code is all there is.
      expect(
        captchaBrokenBecause('the page did not load (-1009)'),
        contains('-1009'),
      );
    });

    test('the site-key line does not blame the person reading it', () {
      // `captchaBroken` already says it is the site's fault and not
      // theirs. A detail that contradicted that would be worse than no
      // detail.
      expect(captchaBrokenBecause('no site key'), contains('site key'));
      expect(captchaBroken, contains('rather than by you'));
    });
  });


  group('whether there is a check at all', () {
    test('a site key means yes', () {
      expect(captchaOn('0x4AAAAAAABkMYinukE8nzYS'), isTrue);
    });

    test('and no key means no', () {
      // The off position, and the state every deployment is in until
      // somebody pastes a key into the console. The forms behave
      // exactly as they did before the captcha existed.
      expect(captchaOn(null), isFalse);
      expect(captchaOn(''), isFalse);
      expect(captchaOn('   '), isFalse);
    });
  });

  group('what it says', () {
    test('when the check has not been passed', () {
      // Asked before anything is sent, because GoTrue's own refusal
      // names the token rather than the box on the screen.
      expect(captchaNotDone.toLowerCase(), contains('security check'));
    });

    test('and where it cannot be drawn', () {
      // The trap worth naming: the dashboard switch protects the whole
      // PROJECT. Android and iOS have no Turnstile widget — it needs a
      // webview this app does not carry — so turning the protection on
      // would lock every phone out of signing in until one exists.
      expect(captchaUnavailable.toLowerCase(), contains('web app'));
      expect(captchaUnavailable, isNot(contains('Turnstile')));
    });
  });
}
