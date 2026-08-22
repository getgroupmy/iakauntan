import 'package:flutter_test/flutter_test.dart';
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
  });
}
