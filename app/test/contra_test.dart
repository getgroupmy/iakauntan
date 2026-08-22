import 'package:flutter_test/flutter_test.dart';
import 'package:iakauntan/src/features/documents/contra_screen.dart';

void main() {
  group('contraSide', () {
    test('says which way the money runs, in a bookkeeper words', () {
      expect(contraSide('receivable'), 'They owe us');
      expect(contraSide('payable'), 'We owe them');
    });
  });

  group('contraSummary', () {
    test('names the party, the money and both sides', () {
      expect(
        contraSummary({
          'party': 'Bina Jaya Enterprise',
          'amount': 5000,
          'invoices': 1,
          'bills': 2,
        }),
        'Bina Jaya Enterprise · RM 5,000.00 · 1 invoice against 2 bills',
      );
    });

    test('and gets the singular right on both counts', () {
      // "1 invoices against 1 bills" is the kind of thing nobody fixes
      // and everybody notices.
      expect(
        contraSummary({
          'party': 'Kak Yah',
          'amount': 100,
          'invoices': 1,
          'bills': 1,
        }),
        'Kak Yah · RM 100.00 · 1 invoice against 1 bill',
      );
    });
  });

  group('contraBalance', () {
    test('is level when both sides come to the same', () {
      final b = contraBalance({'i1': 5000}, {'b1': 5000});
      expect(b.receivable, 5000);
      expect(b.payable, 5000);
      expect(b.difference, 0);
      expect(b.ok, isTrue);
    });

    test('is not level when they do not, and says by how much', () {
      final b = contraBalance({'i1': 8000}, {'b1': 5000});
      expect(b.difference, 3000);
      expect(b.ok, isFalse);
    });

    test('adds several documents on each side', () {
      final b = contraBalance({'i1': 3000}, {'b1': 1000, 'b2': 2000});
      expect(b.ok, isTrue);
      expect(b.payable, 3000);
    });

    test('nothing picked is not a contra', () {
      expect(contraBalance({}, {}).ok, isFalse);
      // Nor is zero on both sides, which is level and still nothing.
      expect(contraBalance({'i1': 0}, {'b1': 0}).ok, isFalse);
    });

    test('a floating point tail does not grey out the button', () {
      // 0.1 + 0.2 is not 0.3 in binary, and a button that stays grey
      // for that reason is unexplainable to the person looking at two
      // identical figures.
      final b = contraBalance({'i1': 0.1, 'i2': 0.2}, {'b1': 0.3});
      expect(b.ok, isTrue);
    });
  });

  group('contraRemainder', () {
    test('says nothing is left when the two cancel', () {
      expect(
        contraRemainder(contraBalance({'i1': 500}, {'b1': 500})),
        'Level — nothing left either way',
      );
    });

    test('says who still owes, and how much', () {
      expect(
        contraRemainder(contraBalance({'i1': 8000}, {'b1': 5000})),
        'RM 3,000.00 more on their side',
      );
      expect(
        contraRemainder(contraBalance({'i1': 5000}, {'b1': 8000})),
        'RM 3,000.00 more on ours',
      );
    });

    test('and says so plainly before anything is picked', () {
      expect(contraRemainder(contraBalance({}, {})), 'Nothing picked yet');
    });
  });
}
