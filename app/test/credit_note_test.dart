import 'package:flutter_test/flutter_test.dart';
import 'package:iakauntan/src/features/documents/credit_dialog.dart';

void main() {
  group('creditLineLabel', () {
    test('an untouched line just says what was invoiced', () {
      expect(
        creditLineLabel({'invoiced': 5, 'credited': 0, 'remaining': 5}),
        '5 invoiced',
      );
    });

    test('a partly credited one shows all three numbers', () {
      expect(
        creditLineLabel({'invoiced': 5, 'credited': 2, 'remaining': 3}),
        '5 invoiced · 2 credited · 3 left',
      );
    });

    test('and a finished one says so rather than offering a box', () {
      // A field that will be refused is worse than no field.
      expect(
        creditLineLabel({'invoiced': 5, 'credited': 5, 'remaining': 0}),
        'All 5 already credited',
      );
    });
  });

  group('creditTotal', () {
    final rows = [
      {'line_id': 'a', 'unit_price': 12.00},
      {'line_id': 'b', 'unit_price': 4.50},
    ];

    test('is what the customer gets back at the invoice’s own prices', () {
      expect(creditTotal(rows, {'a': 2, 'b': 1}), 28.50);
    });

    test('counting only the lines actually asked for', () {
      expect(creditTotal(rows, {'a': 1}), 12.00);
    });

    test('and nothing at all before anything is typed', () {
      expect(creditTotal(rows, const {}), 0);
    });
  });

  group('hasCreditable', () {
    test('true while any line has something left', () {
      expect(
        hasCreditable([
          {'remaining': 0},
          {'remaining': 3},
        ]),
        isTrue,
      );
    });

    test('false once the whole invoice has been credited', () {
      expect(
        hasCreditable([
          {'remaining': 0},
          {'remaining': 0},
        ]),
        isFalse,
      );
    });

    test('and false for an invoice with no lines at all', () {
      expect(hasCreditable(const []), isFalse);
    });
  });
}
