import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/core/format.dart';

/// Money at the currency's own precision. `Fmt.money`.
///
/// `Currency.decimalPlaces` has carried this since `0002` with a comment
/// saying exactly why — "Yen and won have none. Kept because a rate
/// field that offers cents on a currency without them invites a figure
/// that cannot be paid" — and nothing read it. So every foreign invoice,
/// statement and PDF printed `JPY 1,200.00` for an amount that has no
/// sen.
///
/// The figure was right. The way it was written was not, and it goes to
/// the customer.
void main() {
  group('a currency with no minor unit', () {
    test('prints no decimals', () {
      expect(Fmt.money(1200, currency: 'JPY'), 'JPY 1,200');
      expect(Fmt.money(1200, currency: 'KRW'), 'KRW 1,200');
      expect(Fmt.money(1200, currency: 'VND'), 'VND 1,200');
    });

    test('and still groups its thousands', () {
      expect(Fmt.money(1234567, currency: 'JPY'), 'JPY 1,234,567');
    });

    test('and rounds rather than truncating, if it is ever handed a part',
        () {
      // Nothing should produce a fractional yen, but a rate conversion
      // can, and dropping the fraction silently would understate it.
      expect(Fmt.money(1200.6, currency: 'JPY'), 'JPY 1,201');
    });
  });

  group('everything else keeps its two', () {
    test('ringgit, which is the whole point of the default', () {
      expect(Fmt.money(1234.5), 'RM 1,234.50');
      expect(Fmt.money(1234.5, currency: 'MYR'), 'RM 1,234.50');
    });

    test('and a currency nobody has seeded', () {
      // Two is the right guess for an unknown code: it is what all but
      // a handful of ISO 4217 currencies use.
      expect(Fmt.money(1234.5, currency: 'ZZZ'), 'ZZZ 1,234.50');
    });

    test('and the dollar', () {
      expect(Fmt.money(1234.5, currency: 'USD'), 'USD 1,234.50');
    });
  });

  group('the precision is built from the number, not chosen from a list', () {
    // The first version was a `switch` with an arm for 0, an arm for 3
    // and a default of 2 — and the arm for 3 was unreachable, because no
    // seeded currency has three decimals. Deleting it would have been
    // worse than leaving it: the gate makes the map follow the seed, so
    // the day somebody seeds a dinar the map gains a 3, and a formatter
    // that knew only 0 and 2 would have printed it wrongly and said
    // nothing.
    test('any precision formats at that precision', () {
      expect(Fmt.amountAt(1234.5678, 0), '1,235');
      expect(Fmt.amountAt(1234.5678, 2), '1,234.57');
      expect(Fmt.amountAt(1234.5678, 3), '1,234.568');
      expect(Fmt.amountAt(1234.5678, 4), '1,234.5678');
    });

    test('and none of them loses the thousands separator', () {
      for (final places in const [0, 2, 3, 4]) {
        expect(Fmt.amountAt(1234567, places), startsWith('1,234,567'));
      }
    });

    test('a null amount is nothing, not a crash', () {
      expect(Fmt.amountAt(null, 2), '0.00');
      expect(Fmt.amountAt(null, 0), '0');
    });
  });

  group('the lookup itself', () {
    test('knows the exceptions and assumes two for the rest', () {
      expect(Fmt.currencyDecimals('JPY'), 0);
      expect(Fmt.currencyDecimals('MYR'), 2);
      expect(Fmt.currencyDecimals('ZZZ'), 2);
    });

    // A currency code arrives from the database upper-cased, but a
    // document editor and a URL do not have to.
    test('and is not fooled by the case it arrives in', () {
      expect(Fmt.currencyDecimals('jpy'), 0);
      expect(Fmt.money(1200, currency: 'jpy'), 'jpy 1,200');
    });

    test('only the exceptions are listed', () {
      // Writing out the nineteen seeded currencies that use 2 would be
      // nineteen chances to type 3.
      expect(Fmt.currencyDecimalsBy.values, everyElement(isNot(2)));
      expect(Fmt.currencyDecimalsBy.keys, hasLength(3));
    });
  });
}
