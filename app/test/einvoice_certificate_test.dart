import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/features/settings/einvoice_certificate_card.dart';

/// What the screen says about a certificate's remaining life. `0615`.
///
/// Signing with an expired certificate is not a degraded mode: every
/// version 1.1 e-Invoice from that moment on is rejected, and the
/// rejection names the signature rather than the date. So the warning
/// has to arrive while there is still time to do something, and a
/// renewal takes weeks with most Malaysian certification authorities.
void main() {
  final today = DateTime(2026, 9, 16);

  DateTime inDays(int days) => today.add(Duration(days: days));

  group('when to say something', () {
    test('a certificate with a year left says nothing', () {
      expect(certificateWarning(inDays(365), now: today), isNull);
    });

    test('nor does one with two months', () {
      expect(certificateWarning(inDays(61), now: today), isNull);
    });

    test('a month out, it says how long and what that means', () {
      final warning = certificateWarning(inDays(29), now: today);
      expect(warning, isNotNull);
      expect(warning, contains('29 days'));
      // The sentence that makes it actionable rather than informative.
      expect(warning, contains('renewal takes longer'));
    });

    test('one day is a day, not days', () {
      // A pedantic assertion that has earned its place: "expires in 1
      // days" is the line somebody screenshots.
      expect(certificateWarning(inDays(1), now: today), contains('in 1 day,'));
    });

    test('an expired one says every invoice will be rejected', () {
      final warning = certificateWarning(inDays(-1), now: today);
      expect(warning, contains('expired'));
      expect(warning, contains('rejected'));
      // And what to do, because "expired" on its own is a state and not
      // an instruction.
      expect(warning, contains('renew'));
    });

    test('no certificate on file is not a warning', () {
      // The card says something else in that case — "none on file" —
      // and a warning here would be a second, contradictory sentence.
      expect(certificateWarning(null, now: today), isNull);
    });
  });

  group('which kind of warning it is', () {
    test('expired is expired', () {
      expect(certificateHasExpired(inDays(-1), now: today), isTrue);
    });

    test('expiring is not', () {
      // The two are drawn differently — red against amber — and the
      // difference is whether it has already gone wrong.
      expect(certificateHasExpired(inDays(3), now: today), isFalse);
    });

    test('and nothing on file is not either', () {
      expect(certificateHasExpired(null, now: today), isFalse);
    });

    test('the boundary is the moment, not the day', () {
      // A certificate expiring at nine this morning is expired at ten,
      // and MyInvois agrees. Rounding to whole days would have it still
      // usable until midnight.
      final nineToday = DateTime(2026, 9, 16, 9);
      expect(
        certificateHasExpired(nineToday, now: DateTime(2026, 9, 16, 10)),
        isTrue,
      );
      expect(
        certificateHasExpired(nineToday, now: DateTime(2026, 9, 16, 8)),
        isFalse,
      );
    });
  });
}
