import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/features/auth/reset_cooldown.dart';

/// The sign-in link.
///
/// `0613`. Two things about it are decisions rather than wording, and
/// both are about not turning a sign-in form into something else:
///
///   * it says the same thing for an address that has an account and
///     one that does not, because two answers would let anybody find
///     out who has an account here by typing;
///   * it has its own wait, not the password reset's.
///
/// The words themselves are asserted because they are the whole of what
/// somebody gets: there is no screen after this, only an inbox.
void main() {
  group('what it says when a link has gone', () {
    test('it does not claim one was sent', () {
      // GoTrue answers identically whether or not the address is
      // registered, so "we have sent you a link" is untrue half the
      // time — and a sentence that is true only half the time is how
      // somebody with a typo waits all afternoon.
      final said = magicLinkSent('kabeer@example.com');
      expect(said, contains('If there is an account'));
      expect(said, isNot(contains('We have sent')));
    });

    test('and names the address, so a typo is visible in the answer', () {
      expect(
        magicLinkSent('kabeer@exapmle.com'),
        contains('kabeer@exapmle.com'),
      );
    });

    test('it says what arrives, which is not a reset', () {
      // Somebody told "a reset link is on its way" who then receives a
      // sign-in link clicks it looking for a password box.
      final said = magicLinkSent('a@b.com');
      expect(said, contains('sign-in link'));
      expect(said, isNot(contains('reset')));
    });

    test('and the reset still says reset', () {
      // The control: the two messages are different on purpose, and an
      // assertion that only checked one would pass on a copy-paste.
      expect(resetSent('a@b.com'), contains('reset link'));
      expect(resetSent('a@b.com'), isNot(contains('sign-in link')));
    });

    test('it says what to do when nothing arrives', () {
      expect(magicLinkSent('a@b.com'), contains('typo'));
      expect(magicLinkSent('a@b.com'), contains('spam'));
    });
  });

  group('the wait', () {
    test('says how long is left', () {
      expect(
        magicLinkTooSoon(const Duration(seconds: 40)),
        contains('40 seconds'),
      );
    });

    test('and calls it a sign-in link, not a reset', () {
      final said = magicLinkTooSoon(const Duration(minutes: 2));
      expect(said, contains('sign-in link'));
      expect(said, isNot(contains('reset password')));
    });

    test('while the reset wait still calls it a reset', () {
      expect(
        tooSoonMessage(const Duration(minutes: 2)),
        contains('reset password'),
      );
    });
  });

  group('the address check is shared, and should be', () {
    test('a missing @ is a typo either way', () {
      // Named on the spot rather than sent nowhere. The same rule
      // applies to both buttons because it is the same box.
      expect(looksLikeAnAddress('kabeer2hotmail.com'), isFalse);
      expect(looksLikeAnAddress('kabeer2@hotmail'), isFalse);
      expect(looksLikeAnAddress('kabeer2@hotmail.com'), isTrue);
    });
  });
}
