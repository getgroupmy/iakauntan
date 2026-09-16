import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/core/format.dart';

/// Reading a figure out of a field somebody typed into.
///
/// `double.tryParse(text) ?? 0` appears about two hundred times in this
/// app and is harmless in most of them. In a few it is the opposite of
/// harmless, because zero is not a small value there -- it is the OFF
/// position:
///
///   * `contacts.credit_limit`. The field's own helper text says "Zero
///     means no limit", and `0467_cash_is_not_credit.sql` agrees:
///     `if coalesce(v_limit, 0) <= 0 then return new`. So a credit
///     limit that fails to parse does not become a cautious limit. It
///     removes the limit, on a customer somebody was trying to cap.
///   * a statutory rate. Zero is no contribution on a payslip.
///
/// Both fail OPEN and neither says anything. `typedNumber` returns null
/// instead, so the field can refuse.
///
/// The interesting half of this is what it will NOT guess at.
void main() {
  group('a plain figure', () {
    test('parses', () {
      expect(Fmt.typedNumber('5000'), 5000);
      expect(Fmt.typedNumber('5000.50'), 5000.50);
      expect(Fmt.typedNumber('0'), 0);
      expect(Fmt.typedNumber('0.00'), 0);
      expect(Fmt.typedNumber('.5'), 0.5);
      expect(Fmt.typedNumber('11.'), 11);
    });

    test('and so does one with room around it', () {
      expect(Fmt.typedNumber('  5000  '), 5000);
      expect(Fmt.typedNumber('5 000'), 5000);
    });
  });

  group('what people put around a figure', () {
    test('the currency they were shown in the prefix', () {
      // The field draws "RM " as a prefix, which is exactly why somebody
      // types it again.
      expect(Fmt.typedNumber('RM 10000'), 10000);
      expect(Fmt.typedNumber('rm10000'), 10000);
      expect(Fmt.typedNumber('MYR 10,000.00'), 10000);
    });

    test('and the per-cent sign on a field labelled Employee %', () {
      expect(Fmt.typedNumber('11'), 11);
      expect(Fmt.typedNumber('11%'), 11);
      expect(Fmt.typedNumber('11.5 %'), 11.5);
    });

    test('grouping commas, which is how money is written', () {
      expect(Fmt.typedNumber('10,000'), 10000);
      expect(Fmt.typedNumber('1,234,567.89'), 1234567.89);
      expect(Fmt.typedNumber('999'), 999);
    });
  });

  group('what it refuses rather than guesses', () {
    test('a comma that is not a grouping separator', () {
      // This is the one worth the whole function. Half the world writes
      // 11,5 for eleven and a half. Stripping the comma reads it as a
      // hundred and fifteen -- a ten-fold error on an EPF rate, arrived
      // at silently, on every payslip in the company.
      expect(Fmt.typedNumber('11,5'), isNull);
      expect(Fmt.typedNumber('1,23'), isNull);
      expect(Fmt.typedNumber('10,00'), isNull);
      expect(Fmt.typedNumber('1,2345'), isNull);
      expect(Fmt.typedNumber('1234,567'), isNull);
    });

    test('words, and a field with nothing in it', () {
      expect(Fmt.typedNumber(''), isNull);
      expect(Fmt.typedNumber('   '), isNull);
      expect(Fmt.typedNumber('none'), isNull);
      expect(Fmt.typedNumber('n/a'), isNull);
      expect(Fmt.typedNumber('RM'), isNull);
      expect(Fmt.typedNumber('%'), isNull);
      expect(Fmt.typedNumber('5000-'), isNull);
      expect(Fmt.typedNumber('5.0.0'), isNull);
    });

    test('and the three things double.tryParse accepts that nobody typed',
        () {
      // `double.tryParse` reads all of these. None is a figure anybody
      // meant to put in a money field, and each would sail through as a
      // number: 1e9 is a billion-ringgit credit limit from three
      // keystrokes, and Infinity and NaN both survive as far as the
      // database.
      expect(double.tryParse('1e9'), isNotNull);
      expect(double.tryParse('Infinity'), isNotNull);
      expect(double.tryParse('0x10'), isNull);

      expect(Fmt.typedNumber('1e9'), isNull);
      expect(Fmt.typedNumber('Infinity'), isNull);
      expect(Fmt.typedNumber('NaN'), isNull);
      expect(Fmt.typedNumber('0x10'), isNull);
    });
  });

  group('a sign', () {
    test('is kept, because the caller decides whether it is allowed', () {
      // Not refused here. A credit limit below zero is nonsense and a
      // journal line below zero is ordinary, and this function does not
      // know which field it is looking at. What it must not do is drop
      // the minus and hand back a positive number.
      expect(Fmt.typedNumber('-1'), -1);
      expect(Fmt.typedNumber('-1,000.50'), -1000.50);
      expect(Fmt.typedNumber('+250'), 250);
    });
  });

  test('and zero is a number, not an absence', () {
    // The distinction the whole thing rests on: typing 0 into the credit
    // limit is somebody saying "no limit" on purpose, and it has to stay
    // possible. Only text that is not a figure comes back null.
    expect(Fmt.typedNumber('0'), isNotNull);
    expect(Fmt.typedNumber('0'), 0);
    expect(Fmt.typedNumber('not a number'), isNull);
  });
}
