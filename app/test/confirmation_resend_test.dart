import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/features/auth/confirmation_resend.dart';

/// The way out of an unconfirmed address.
///
/// Somebody signs up, the confirmation goes astray, and every attempt
/// to sign in answers "Email not confirmed" with nothing to do about
/// it — the only way on being to register again with the same address,
/// which the form does not allow. The button that fixes that is
/// offered on one condition, and getting the condition wrong is the
/// whole risk: too narrow and the dead end stays for the people whose
/// GoTrue sends a different sentence; too wide and a failed sign-in
/// starts emailing addresses to find out whether they are registered.
void main() {
  group('when the offer appears', () {
    test('on the code, which is the stable half', () {
      expect(looksUnconfirmed(code: 'email_not_confirmed'), isTrue);
    });

    test('and on the message, which is all older versions send', () {
      // The password grant sends this sentence and no code.
      expect(looksUnconfirmed(message: 'Email not confirmed'), isTrue);
    });

    test('in either case', () {
      expect(looksUnconfirmed(message: 'email not confirmed'), isTrue);
      expect(looksUnconfirmed(code: 'EMAIL_NOT_CONFIRMED'), isTrue);
    });
  });

  group('when it does not', () {
    test('a wrong password is not an unconfirmed address', () {
      // The one that matters. A button here would email any address
      // somebody typed, which turns a failed sign-in into a way to ask
      // whether an account exists.
      expect(
        looksUnconfirmed(
          code: 'invalid_credentials',
          message: 'Invalid login credentials',
        ),
        isFalse,
      );
    });

    test('nor is a missing account, or nothing at all', () {
      expect(looksUnconfirmed(message: 'User not found'), isFalse);
      expect(looksUnconfirmed(), isFalse);
      expect(looksUnconfirmed(message: ''), isFalse);
    });
  });

  group('pressing it twice', () {
    test('the rate limit is recognised by code', () {
      expect(looksRateLimited(code: 'over_email_send_rate_limit'), isTrue);
      expect(looksRateLimited(code: 'over_request_rate_limit'), isTrue);
    });

    test('and by the sentence GoTrue actually sends', () {
      // What arrives in practice: "For security purposes, you can only
      // request this after 47 seconds."
      expect(
        looksRateLimited(
          message: 'For security purposes, you can only request this '
              'after 47 seconds.',
        ),
        isTrue,
      );
    });

    test('an ordinary failure is not a rate limit', () {
      expect(looksRateLimited(message: 'Invalid login credentials'), isFalse);
    });
  });

  group('what it says', () {
    test('the confirmation names the address it went to', () {
      // The commonest reason a confirmation never arrives is that it
      // went somewhere else, and somebody looking at their own typo is
      // the fastest fix available.
      final sent = resendConfirmationSent('kabeer2@hotmail.com');
      expect(sent, contains('kabeer2@hotmail.com'));
      expect(sent, contains('spam'));
    });

    test('too soon says how long, and what to do meanwhile', () {
      expect(resendConfirmationTooSoon, contains('a minute'));
      expect(resendConfirmationTooSoon, contains('spam'));
    });

    test('a failure carries the reason rather than swallowing it', () {
      final failed = resendConfirmationFailed('Invalid email address');
      expect(failed, contains('Invalid email address'));
      expect(failed, isNot(contains('something went wrong')));
    });

    test('the button says what it does', () {
      expect(resendConfirmationLabel, contains('again'));
      expect(resendConfirmationLabel.toLowerCase(), contains('confirmation'));
    });
  });
}
