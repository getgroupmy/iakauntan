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
