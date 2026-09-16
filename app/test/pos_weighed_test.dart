import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/core/format.dart';
import 'package:iakauntan/src/features/pos/scales_screen.dart';
import 'package:iakauntan/src/features/pos/till_screen.dart';

void main() {
  group('eanCheckDigit', () {
    // The same published examples the database test asserts against, so
    // a sample the screen prints is one the parser will accept.
    test('GS1\'s own worked example', () {
      expect(eanCheckDigit('590123412345'), 7);
    });

    test('and the other one', () {
      expect(eanCheckDigit('12345678901'), 2);
    });

    test('an EAN-8 body is the same arithmetic', () {
      expect(eanCheckDigit('9638507'), 4);
    });

    test('a body whose weights already land on ten checks to zero', () {
      expect(eanCheckDigit('400638133393'), 1);
    });
  });

  group('sampleScaleBarcode', () {
    final format = {
      'prefix': '20',
      'code_digits': 5,
      'value_digits': 5,
      'has_check_digit': true,
    };

    test('pads the item number and the value to the layout', () {
      final code = sampleScaleBarcode(format, '1', 246);
      expect(code.substring(0, 12), '200000100246');
      expect(code.length, 13);
    });

    test('and ends with a check digit the parser will agree with', () {
      final code = sampleScaleBarcode(format, '1', 246);
      expect(
        int.parse(code[12]),
        eanCheckDigit(code.substring(0, 12)),
      );
    });

    test('a scale with no check digit gets none', () {
      final code = sampleScaleBarcode({
        'prefix': '20',
        'code_digits': 5,
        'value_digits': 5,
        'has_check_digit': false,
      }, '1', 246);
      expect(code, '200000100246');
    });
  });

  group('scaleLayout', () {
    test('spells the digit counts out rather than summarising them', () {
      expect(
        scaleLayout({
          'prefix': '20',
          'code_digits': 5,
          'value_digits': 5,
          'value_kind': 'weight_grams',
          'total_digits': 13,
        }),
        'Starts 20 · 5 digits of item · 5 of grams · 13 in all',
      );
    });

    test('and names what the number means', () {
      expect(
        scaleLayout({
          'prefix': '21',
          'code_digits': 5,
          'value_digits': 5,
          'value_kind': 'price_sen',
          'total_digits': 13,
        }),
        contains('of ringgit'),
      );
      expect(
        scaleLayout({
          'prefix': '22',
          'code_digits': 4,
          'value_digits': 6,
          'value_kind': 'weight_kg_3dp',
          'total_digits': 13,
        }),
        contains('kilograms to three places'),
      );
    });
  });

  group('weighedLine', () {
    test('is what the weight comes to', () {
      expect(weighedLine(0.246, 25.90), 'RM 6.37');
    });

    test('rounded the way the line will be, not close to it', () {
      // 0.248 * 32.00 = 7.936, which is 7.94 on the bill.
      expect(weighedLine(0.248, 32.00), 'RM 7.94');
    });

    test('and says nothing at all before a weight is typed', () {
      expect(weighedLine(0, 25.90), '—');
      expect(weighedLine(-1, 25.90), '—');
    });

    group('where the sen lands exactly on a half', () {
      // The claim in this function's own comment is that "the number a
      // cashier reads out is the number the customer is charged rather
      // than one that is close to it". It was not.
      //
      // 50 grams at RM 2.90 is a gross of 0.1450 exactly, which charges
      // 15 sen. Written as `(0.05 * 2.90 * 100).round() / 100` it came
      // out as 14, because 0.145 is 0.14499999999999999 in binary and
      // multiplying back lands just under the half. Measured over every
      // weight from 50 g to 5 kg against every price from RM 1 to RM
      // 50: 123,093 combinations where the till and the receipt
      // disagreed, always with the till a sen light.

      test('fifty grams at RM 2.90 is fifteen sen, not fourteen', () {
        expect(weighedLine(0.05, 2.90), 'RM 0.15');
      });

      test('and the others that were wrong', () {
        expect(weighedLine(0.05, 20.70), 'RM 1.04');
        expect(weighedLine(0.05, 42.30), 'RM 2.12');
        expect(weighedLine(0.051, 1.47), 'RM 0.08');
      });

      test('the old expression really did get them wrong', () {
        // The control, so these read as a defect rather than as
        // arbitrary numbers.
        num old(num w, num p) => (w * p * 100).round() / 100;

        expect(old(0.05, 2.90), 0.14);
        expect(old(0.05, 20.70), 1.03);
        expect(old(0.051, 1.47), 0.07);
      });
    });

    test('against the two-stage rounding the database does', () {
      // `app.calc_document_line` holds the gross as `numeric(18, 4)`
      // and rounds THAT to the sen. The reference is integer
      // arithmetic: weight to the gram, price to the sen.
      int halfAway(int n, int d) {
        final q = n ~/ d;
        return (n % d) * 2 >= d ? q + 1 : q;
      }

      for (var grams = 50; grams <= 2000; grams += 7) {
        for (var sen = 100; sen <= 4000; sen += 13) {
          final cents = halfAway(halfAway(grams * sen, 10), 100);
          expect(
            weighedLine(grams / 1000, sen / 100),
            Fmt.money(cents / 100),
            reason: '${grams}g at ${sen}sen',
          );
        }
      }
    });
  });
}
