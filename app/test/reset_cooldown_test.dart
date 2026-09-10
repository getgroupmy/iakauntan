import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/features/auth/reset_cooldown.dart';

/// What "Forgot password?" says when it has just been pressed.
///
/// Reported: pressing it twice answered
///
///   AuthApiException(message: For security purposes, you can only
///   request this after 5 seconds., statusCode: 429, code:
///   over_email_send_rate_limit)
///
/// which names a Dart class, an HTTP status and an error code, and
/// buries the only fact somebody needed: they have to wait, and for how
/// long.
void main() {
  group('how long to wait', () {
    test('five minutes, and it is ours rather than the server\'s', () {
      // The project's own security interval is seconds. A reset link
      // that can be asked for every few seconds is a way to fill
      // somebody's inbox using nothing but their address.
      expect(resetCooldown, const Duration(minutes: 5));
    });

    test('what GoTrue says, where it says anything', () {
      expect(
        statedWait('For security purposes, you can only request this '
            'after 47 seconds.'),
        const Duration(seconds: 47),
      );
      expect(
        statedWait('you can only request this after 2 minutes'),
        const Duration(minutes: 2),
      );
    });

    test('and nothing where it does not', () {
      // The caller falls back to our five minutes rather than to zero,
      // which would be a countdown that says "try again now" to
      // somebody the server is about to refuse.
      expect(statedWait('Something else went wrong'), isNull);
      expect(statedWait(null), isNull);
      expect(statedWait(''), isNull);
    });
  });

  group('what counts as too soon', () {
    test('the code, which is the stable half', () {
      expect(looksTooSoon(code: 'over_email_send_rate_limit'), isTrue);
      expect(looksTooSoon(code: 'over_request_rate_limit'), isTrue);
    });

    test('and the sentence, which is all older versions send', () {
      expect(
        looksTooSoon(
            message: 'For security purposes, you can only request this '
                'after 5 seconds.'),
        isTrue,
      );
    });

    test('a real failure is not a wait', () {
      // The one that matters: telling somebody to wait five minutes
      // when their address is wrong leaves them waiting five minutes.
      expect(
        looksTooSoon(code: 'validation_failed', message: 'Invalid email'),
        isFalse,
      );
      expect(looksTooSoon(), isFalse);
    });
  });

  group('what is left of the wait', () {
    final now = DateTime(2026, 9, 10, 17, 0);

    test('counts down from the moment it was asked for', () {
      expect(
        remainingWait(now.subtract(const Duration(minutes: 1)), now),
        const Duration(minutes: 4),
      );
    });

    test('is nothing once it has passed', () {
      // Zero rather than a negative duration, so "nothing left" and
      // "never asked" are the same thing to a caller.
      expect(
        remainingWait(now.subtract(const Duration(minutes: 6)), now),
        Duration.zero,
      );
      expect(remainingWait(null, now), Duration.zero);
    });
  });

  group('what it reads as', () {
    test('minutes and seconds, the way somebody reads a clock', () {
      expect(waitFor(const Duration(minutes: 4, seconds: 12)),
          '4 min 12 seconds');
      expect(waitFor(const Duration(minutes: 5)), '5 min 0 seconds');
    });

    test('and seconds alone under a minute', () {
      // "0 min 12 seconds" is a sentence written by a computer.
      expect(waitFor(const Duration(seconds: 12)), '12 seconds');
      expect(waitFor(const Duration(seconds: 1)), '1 second');
      expect(waitFor(Duration.zero), '1 second');
    });

    test('the sentence says how long and that trying now will not help',
        () {
      final said = tooSoonMessage(const Duration(minutes: 4, seconds: 12));
      expect(said, contains('4 min 12 seconds'));
      expect(said.toLowerCase(), contains('for security reasons'));
      expect(said.toLowerCase(), contains('try again later'));
    });

    test('and never the shape of the thing that refused it', () {
      // The assertion that would fail if the banner went back to
      // printing the exception.
      final said = tooSoonMessage(const Duration(minutes: 5));
      expect(said, isNot(contains('AuthApiException')));
      expect(said, isNot(contains('429')));
      expect(said, isNot(contains('statusCode')));
      expect(said, isNot(contains('over_email_send_rate_limit')));
    });

    test('and the sent message says where to look for it', () {
      final sent = resetSent('kabeer2@hotmail.com');
      expect(sent, contains('kabeer2@hotmail.com'));
      expect(sent, contains('spam'));
    });
  });
}
