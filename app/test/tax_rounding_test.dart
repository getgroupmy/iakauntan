import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/core/format.dart';

/// A percentage of money, rounded the way the database rounds it.
///
/// `0099_withholding_tax.sql` states the rule, and it is the house rule
/// for every percentage of money here:
///
///     v_gross := round(coalesce(p_gross_amount, ...), 2);
///     v_tax   := round(v_gross * v_rate / 100.0, 2);
///
/// Round the base to cents, then compute, then round. Postgres
/// `numeric` is exact decimal and gets the half-up for nothing. A
/// double does not, and the obvious transcription —
///
///     ((amount * rate / 100) * 100).roundToDouble() / 100
///
/// — was written twice in this app and is wrong. `2.90 * 5 / 100` is
/// 0.145 in decimal and 0.14499999999999999 in binary, so multiplying
/// back gives 14.499999999999998 and it rounds DOWN.
///
/// Always down. The error can only push a value that sits exactly on a
/// half-cent off it, and binary fractions of this shape fall short
/// rather than over — so the mistake never over-collects, it
/// under-collects, which is the direction a tax authority minds.
///
/// The two places it was written:
///
///   * `expenses_screen.dart`, where the figure is STORED --
///     `recordExpense` inserts it as `tax_amount` and `0286` only
///     checks the total agrees with it, so nothing downstream would
///     ever have noticed;
///   * `withholding_dialog.dart`, where it is a preview of what
///     `create_withholding` will withhold. A preview that disagrees
///     with the certificate by a cent is worse than no preview.
void main() {
  /// The exact answer, in integers, with no float anywhere near it.
  ///
  /// Tax in cents is `cents * rate / 100`. With the rate itself scaled
  /// to hundredths of a per cent the whole thing is one integer
  /// division, rounded half away from zero the way both Postgres and
  /// Dart's `roundToDouble` do.
  int exactTaxCents(int cents, double ratePercent) {
    final rateHundredths = (ratePercent * 100).round();
    final numerator = cents * rateHundredths;
    const denom = 10000;
    final q = numerator ~/ denom;
    final r = numerator % denom;
    return r * 2 >= denom ? q + 1 : q;
  }

  group('the cases that were wrong', () {
    // Each of these was measured against the old expression before it
    // was replaced, and each came out a cent low.
    test('an RM 2.90 expense at 5 per cent is fifteen sen, not fourteen',
        () {
      expect(Fmt.taxOn(2.90, 5), 0.15);
    });

    test('RM 4.75 at 6 per cent is twenty-nine sen', () {
      expect(Fmt.taxOn(4.75, 6), 0.29);
    });

    test('RM 1.45 at 10 per cent is fifteen sen', () {
      expect(Fmt.taxOn(1.45, 10), 0.15);
    });

    test('RM 102.00 at 8.25 per cent is 8.42', () {
      // A fractional rate, which the old expression also got wrong.
      expect(Fmt.taxOn(102.00, 8.25), 8.42);
    });

    test('and the old expression really did get them wrong', () {
      // The control for this whole file. Without it every assertion
      // above is just a number, and nobody reading them later can tell
      // which were the bug and which were always fine.
      double old(double amount, double rate) =>
          ((amount * rate / 100) * 100).roundToDouble() / 100;

      expect(old(2.90, 5), 0.14);
      expect(old(4.75, 6), 0.28);
      expect(old(1.45, 10), 0.14);
      expect(old(102.00, 8.25), 8.41);
    });
  });

  group('against exact integer arithmetic', () {
    // A sweep rather than examples. The examples above came OUT of this
    // sweep; keeping only them would leave the next rate unexamined.
    for (final rate in [5.0, 6.0, 8.0, 10.0, 15.0, 2.5, 8.25]) {
      test('every sen from 0.01 to 500.00 at $rate per cent', () {
        for (var cents = 1; cents <= 50000; cents++) {
          final amount = cents / 100;
          final want = exactTaxCents(cents, rate) / 100;
          expect(
            Fmt.taxOn(amount, rate),
            want,
            reason: 'RM $amount at $rate%',
          );
        }
      });
    }

    test('and the old expression fails that same sweep', () {
      // Named, so the size of it is on the record: this is not one
      // unlucky number.
      double old(double amount, double rate) =>
          ((amount * rate / 100) * 100).roundToDouble() / 100;

      var wrong = 0;
      var everHigh = false;
      for (var cents = 1; cents <= 50000; cents++) {
        final got = old(cents / 100, 6);
        final want = exactTaxCents(cents, 6) / 100;
        if (got != want) {
          wrong++;
          if (got > want) everHigh = true;
        }
      }
      // The exact count, not a threshold. 47 of the first fifty
      // thousand sen are wrong at 6 per cent; over every amount up to
      // twenty thousand ringgit it is 2,468.
      expect(wrong, 47);
      // And never once high. The float error can only knock a value
      // OFF a half-cent downwards, so the old expression under-collects
      // and never over-collects -- which is the direction that matters
      // when the figure is remitted.
      expect(everHigh, isFalse);
    });
  });

  group('the ordinary cases still hold', () {
    test('a round figure', () {
      expect(Fmt.taxOn(100, 6), 6.00);
      expect(Fmt.taxOn(1000, 8), 80.00);
    });

    test('no rate is no tax', () {
      expect(Fmt.taxOn(1234.56, 0), 0);
    });

    test('nothing at any rate is nothing', () {
      expect(Fmt.taxOn(0, 6), 0);
    });

    test('a credit note is negative on both sides', () {
      // Rounded away from zero, which is what Postgres `round` does, so
      // a reversal is the exact negative of what it reverses rather
      // than a cent adrift from it.
      expect(Fmt.taxOn(-2.90, 5), -0.15);
      expect(Fmt.taxOn(-4.75, 6), -0.29);
      expect(Fmt.taxOn(-100, 6), -6.00);
    });

    test('a base carrying more than two decimals is rounded first', () {
      // The database rounds the gross before it applies the rate, and
      // this has to do the same or the two disagree on the boundary.
      expect(Fmt.taxOn(2.899, 5), 0.15);
      expect(Fmt.taxOn(2.904, 5), 0.15);
    });
  });
}
