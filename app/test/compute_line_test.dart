import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/features/documents/line_draft.dart';

/// The arithmetic on one line of an invoice.
///
/// `computeLine` says of itself that it "mirrors app.calc_document_line()
/// so the editor can show live totals before a row is saved. The
/// database remains the source of truth." Both halves of that matter:
/// the trigger in `0009_functions.sql` OVERWRITES `line_subtotal`,
/// `tax_amount` and `line_total` on every insert and update, so nothing
/// here can post a wrong figure.
///
/// What it can do is disagree. An editor that shows a total a cent away
/// from the invoice it is about to create is worse than one that shows
/// no total, because the figure it shows is the one somebody checks
/// against the order.
///
/// And it did disagree. Both percentages were written as
///
///     (x * pct / 100 * 100).round() / 100
///
/// which is a cent low whenever the answer lands exactly on a
/// half-cent: `2.90 * 5 / 100` is 0.14499999999999999 in binary, so the
/// multiply-back rounds down. Measured over four million quantity and
/// price combinations, 46,646 discounts were wrong; over every net from
/// one sen to twenty thousand ringgit, 2,468 tax figures at 6 per cent
/// and 9,173 at 10.
///
/// The reference below is integer arithmetic with no float in it, so it
/// is not the implementation written twice.
void main() {
  /// `round(n / d)` with halves away from zero, which is what Postgres
  /// `round` does and what the mirror has to match.
  int halfAway(int n, int d) {
    if (n < 0) return -halfAway(-n, d);
    final q = n ~/ d;
    return (n % d) * 2 >= d ? q + 1 : q;
  }

  /// What `app.calc_document_line` would store, in cents, worked out in
  /// integers. `quantity` is whole and `price` is in cents, which keeps
  /// the gross exact.
  ({int net, int tax}) expected({
    required int quantity,
    required int priceCents,
    required double discountPercent,
    required double taxRate,
  }) {
    // v_gross numeric(18,4), in ten-thousandths.
    final gross4 = quantity * priceCents * 100;
    final discountCents = discountPercent > 0
        ? halfAway(gross4 * (discountPercent * 100).round(), 100 * 10000)
        : 0;
    // gross4 is in ten-thousandths and the discount in cents, so the
    // discount is scaled up to meet it and the difference comes back
    // down by a hundred. Getting this divisor wrong is how the first
    // draft of this reference claimed a one-sen line was worth nothing.
    final netCents = halfAway(gross4 - discountCents * 100, 100);
    final taxCents = halfAway(netCents * (taxRate * 100).round(), 100 * 100);
    return (net: netCents, tax: taxCents);
  }

  ({double net, double tax, double total}) line({
    double quantity = 1,
    double unitPrice = 0,
    double discountPercent = 0,
    double discountAmount = 0,
    double taxRate = 0,
    bool taxInclusive = false,
  }) => computeLine(
    quantity: quantity,
    unitPrice: unitPrice,
    discountPercent: discountPercent,
    discountAmount: discountAmount,
    taxRate: taxRate,
    taxInclusive: taxInclusive,
  );

  group('the half-cent cases that were wrong', () {
    test('5 per cent off one unit at RM 2.90 is fifteen sen, not fourteen',
        () {
      // Discount 0.15, so net is 2.75.
      final r = line(quantity: 1, unitPrice: 2.90, discountPercent: 5);
      expect(r.net, 2.75);
    });

    test('6 per cent tax on a net of RM 4.75 is twenty-nine sen', () {
      final r = line(quantity: 1, unitPrice: 4.75, taxRate: 6);
      expect(r.tax, 0.29);
      expect(r.total, 5.04);
    });

    test('10 per cent tax on RM 1.45 is fifteen sen', () {
      expect(line(quantity: 1, unitPrice: 1.45, taxRate: 10).tax, 0.15);
    });

    test('and the old expression really did get them wrong', () {
      // The control. Without it these read as arbitrary numbers and
      // nobody can tell which were the defect.
      double old(double v) => (v * 100).roundToDouble() / 100;

      expect(old(2.90 * 5 / 100), 0.14);
      expect(old(4.75 * 6 / 100), 0.28);
      expect(old(1.45 * 10 / 100), 0.14);
    });
  });

  group('against integer arithmetic, with no float in the reference', () {
    for (final rate in [6.0, 10.0, 8.0]) {
      test('tax at $rate per cent, every sen to RM 300', () {
        for (var cents = 1; cents <= 30000; cents++) {
          final want = expected(
            quantity: 1,
            priceCents: cents,
            discountPercent: 0,
            taxRate: rate,
          );
          final got = line(quantity: 1, unitPrice: cents / 100, taxRate: rate);
          expect((got.tax * 100).round(), want.tax,
              reason: 'tax on ${cents / 100} at $rate%');
          expect((got.net * 100).round(), want.net);
        }
      });
    }

    for (final pct in [5.0, 12.5, 33.33]) {
      test('a $pct per cent discount, every sen to RM 300', () {
        for (var cents = 1; cents <= 30000; cents++) {
          final want = expected(
            quantity: 1,
            priceCents: cents,
            discountPercent: pct,
            taxRate: 0,
          );
          final got = line(
            quantity: 1,
            unitPrice: cents / 100,
            discountPercent: pct,
          );
          expect((got.net * 100).round(), want.net,
              reason: 'net after $pct% off ${cents / 100}');
        }
      });
    }

    test('and with a quantity on it', () {
      for (var q = 1; q <= 12; q++) {
        for (var cents = 1; cents <= 3000; cents++) {
          final want = expected(
            quantity: q,
            priceCents: cents,
            discountPercent: 5,
            taxRate: 6,
          );
          final got = line(
            quantity: q.toDouble(),
            unitPrice: cents / 100,
            discountPercent: 5,
            taxRate: 6,
          );
          expect((got.net * 100).round(), want.net,
              reason: '$q x ${cents / 100}');
          expect((got.tax * 100).round(), want.tax,
              reason: '$q x ${cents / 100}');
        }
      }
    });
  });

  group('the rules the trigger sets', () {
    test('a percentage beats a typed amount', () {
      // `if coalesce(new.discount_percent, 0) > 0 then ... else
      // coalesce(new.discount_amount, 0)`. Both given, the percentage
      // wins, and a line that honoured the amount instead would take
      // 50 off rather than 10.
      final r = line(
        quantity: 1,
        unitPrice: 100,
        discountPercent: 10,
        discountAmount: 50,
      );

      expect(r.net, 90);
    });

    test('and a typed amount is used when there is no percentage', () {
      expect(line(quantity: 1, unitPrice: 100, discountAmount: 50).net, 50);
    });

    test('the total is the net plus the tax', () {
      final r = line(quantity: 3, unitPrice: 19.99, taxRate: 6);

      expect(r.total, r.net + r.tax);
    });
  });

  group('a price that already contains the tax', () {
    test('is stripped back out, and the parts add up to what was typed',
        () {
      // The invariant that matters on the inclusive branch: the tax is
      // taken by SUBTRACTION, so net and tax always add back to the
      // gross exactly. A rounding that computed the tax independently
      // would leave a line whose parts do not equal its own price.
      for (final price in [106.0, 10.60, 1.06, 99.99, 0.07, 12345.67]) {
        final r = line(quantity: 1, unitPrice: price, taxRate: 6,
            taxInclusive: true);

        expect(r.net + r.tax, closeTo(price, 0.000001),
            reason: 'inclusive at $price');
        expect(r.total, closeTo(price, 0.000001));
      }
    });

    test('RM 106 at 6 per cent inclusive is 100 and 6', () {
      final r = line(
        quantity: 1,
        unitPrice: 106,
        taxRate: 6,
        taxInclusive: true,
      );

      expect(r.net, 100);
      expect(r.tax, 6);
    });

    test('and the inclusive branch is only taken when there is a rate', () {
      // `if new.is_tax_inclusive and coalesce(new.tax_rate, 0) > 0`.
      // Inclusive with no rate is an ordinary line, not a division by
      // one that quietly rounds.
      final r = line(quantity: 1, unitPrice: 106, taxInclusive: true);

      expect(r.net, 106);
      expect(r.tax, 0);
    });
  });

  group('a line that is not whole units at whole cents', () {
    // Every sweep above uses a whole quantity and a price in exact
    // cents, so the gross is always an exact cent amount and four
    // decimals of it look the same as two. Four mutants survived on
    // that alone. Real lines are 2.5 hours, a quarter of a kilo, a
    // price per thousand -- and that is where `numeric(18, 4)` earns
    // its keep.

    test('the gross keeps four decimals, not two', () {
      // 2.5 x 7.77 is 19.425 exactly. `v_gross numeric(18,4)` holds
      // 19.4250 and `v_net := round(v_gross, 2)` is 19.43. Rounding the
      // gross to cents first gives 19.42 -- a sen lost before the line
      // is even discounted.
      expect(line(quantity: 2.5, unitPrice: 7.77).net, 19.43);
    });

    test('and the discount is taken off that four-decimal gross', () {
      // 0.25 x 1.98 is 0.495. round(0.4950 * 5 / 100, 2) is 0.02.
      // Against a gross rounded to 0.50 first it would be 0.03, and the
      // line would be a sen cheaper than the invoice says.
      final r = line(quantity: 0.25, unitPrice: 1.98, discountPercent: 5);

      expect(r.net, 0.48);
    });

    test('an inclusive price with no rate does not invent negative tax', () {
      // `if new.is_tax_inclusive and coalesce(new.tax_rate, 0) > 0`.
      // Without that second test the line divides by one, rounds the
      // gross UP to a cent, and then subtracts the larger net from the
      // smaller gross: 0.25 x 0.26 came out with tax of MINUS one sen.
      final r = line(quantity: 0.25, unitPrice: 0.26, taxInclusive: true);

      expect(r.net, 0.07);
      expect(r.tax, 0);
      expect(r.tax, isNot(lessThan(0)));
    });

    test('an inclusive tax is subtracted, never recomputed', () {
      // round(0.26 / 1.06, 2) is 0.25, so the tax is 0.01 -- what is
      // left. Computing it from the net instead gives 0.02, and the
      // line then totals 0.27 on a price somebody typed as 0.26.
      final r = line(
        quantity: 1,
        unitPrice: 0.26,
        taxRate: 6,
        taxInclusive: true,
      );

      expect(r.net, 0.25);
      expect(r.tax, 0.01);
      expect(r.total, 0.26);

      // And the other direction, where recomputing would be a sen too
      // LOW rather than too high.
      final b = line(
        quantity: 1,
        unitPrice: 0.62,
        taxRate: 6,
        taxInclusive: true,
      );

      expect(b.net, 0.58);
      expect(b.tax, 0.04);
      expect(b.total, 0.62);
    });
  });

  test('nothing typed is nothing owed', () {
    final r = line();

    expect(r.net, 0);
    expect(r.tax, 0);
    expect(r.total, 0);
  });
}
