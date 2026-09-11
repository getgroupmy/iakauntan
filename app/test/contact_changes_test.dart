import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/features/settings/contact_changes.dart';

/// The two changes that are guarded by the password.
///
/// An email address is where a password reset goes and a mobile number
/// is what somebody is rung on, so both are how an account is
/// recovered. Somebody who walks past an unattended signed-in screen
/// and changes the address owns the account a minute later, and the
/// real owner finds out when their next reset link goes somewhere else.
void main() {
  group('why the password is asked again', () {
    test('the reason is said where it is asked', () {
      // A box demanding a password with no explanation reads as the app
      // being suspicious of the person using it.
      expect(whyPasswordAgain.toLowerCase(), contains('password reset'));
      expect(whyPasswordAgainMobile.toLowerCase(), contains('ring'));
      expect(currentPasswordError(''), isNotNull);
      expect(currentPasswordError(null), isNotNull);
      expect(currentPasswordError('anything'), isNull);
    });
  });

  group('a wrong password', () {
    test('is recognised, by code and by sentence', () {
      expect(looksWrongPassword(code: 'invalid_credentials'), isTrue);
      expect(looksWrongPassword(message: 'Invalid login credentials'), isTrue);
    });

    test('and anything else is not', () {
      // Saying "that password is wrong" about a rate limit sends
      // somebody hunting for a password that is fine.
      expect(
        looksWrongPassword(
            code: 'over_email_send_rate_limit',
            message: 'For security purposes, you can only request this '
                'after 5 seconds.'),
        isFalse,
      );
      expect(looksWrongPassword(), isFalse);
    });

    test('and it says nothing has changed', () {
      // The half somebody actually needs: not whether they typed it
      // wrong, but whether their address moved anyway.
      expect(wrongPassword.toLowerCase(), contains('nothing has changed'));
    });
  });

  group('what happens afterwards', () {
    test('an email change is not a change yet', () {
      // GoTrue sends a confirmation to the NEW address and waits. That
      // is the protection that matters: somebody who changes an address
      // they cannot read has changed nothing.
      final said = emailChangeSent('new@example.com');
      expect(said, contains('new@example.com'));
      expect(said.toLowerCase(), contains('does not change until'));
    });

    test('and a number is, because there is nothing to confirm', () {
      expect(mobileChanged('+60123456789'), contains('+60123456789'));
      expect(mobileRemoved.toLowerCase(), contains('removed'));
    });
  });
}
