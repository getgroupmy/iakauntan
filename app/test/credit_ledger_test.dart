import 'package:flutter_test/flutter_test.dart';
import 'package:iakauntan/src/features/settings/credit_ledger_dialog.dart';

Map<String, dynamic> move(num amount, {String type = 'usage'}) =>
    <String, dynamic>{'entry_type': type, 'amount': amount};

void main() {
  group('what a movement is', () {
    test('each type in the words a company would use', () {
      expect(creditMovement('topup'), 'Credit bought');
      expect(creditMovement('usage'), 'A scan');
      expect(creditMovement('refund'), 'Refunded');
      expect(creditMovement('adjustment'), 'Adjustment');
    });

    test('anything unexpected reads as an adjustment', () {
      // The check constraint allows four; a fifth appearing means
      // somebody widened it, and "Adjustment" is the honest fallback
      // rather than a blank.
      expect(creditMovement(null), 'Adjustment');
      expect(creditMovement('something_new'), 'Adjustment');
    });
  });

  group('which way it went', () {
    test('the sign decides, not the type', () {
      // "An adjustment can be either, which is why the sign lives here
      // and not in the type."
      expect(creditWentIn(50), isTrue);
      expect(creditWentIn(-50), isFalse);
    });

    test('an adjustment can go either way', () {
      expect(creditWentIn(20), isTrue);
      expect(creditWentIn(-20), isFalse);
    });

    test('nothing is not credit arriving', () {
      // The column refuses a zero, so this only arises when an amount
      // fails to parse and falls back on one — and a row of nothing
      // must not be coloured as money coming in.
      expect(creditWentIn(0), isFalse);
    });
  });

  group('what went in and what went out', () {
    test('are stated separately, not netted', () {
      // A company that bought a hundred and spent ninety is in a
      // different position from one that bought ten and spent nothing,
      // and the balance alone cannot tell them apart.
      final f = creditFlows([
        move(100, type: 'topup'),
        move(-90),
      ]);
      expect(f.inTotal, 100);
      expect(f.outTotal, 90);
    });

    test('what went out is stated as a positive', () {
      final f = creditFlows([move(-12.50)]);
      expect(f.outTotal, 12.50);
    });

    test('an adjustment lands on whichever side its sign says', () {
      final f = creditFlows([
        move(5, type: 'adjustment'),
        move(-5, type: 'adjustment'),
      ]);
      expect(f.inTotal, 5);
      expect(f.outTotal, 5);
    });

    test('both round to the sen', () {
      final f = creditFlows([
        move(0.1, type: 'topup'),
        move(0.2, type: 'topup'),
        move(-0.1),
        move(-0.2),
      ]);
      expect(f.inTotal, 0.30);
      expect(f.outTotal, 0.30);
    });

    test('an empty ledger is two zeroes', () {
      final f = creditFlows(const []);
      expect(f.inTotal, 0);
      expect(f.outTotal, 0);
    });

    test('amounts that arrive as strings still add up', () {
      final f = creditFlows([
        <String, dynamic>{'amount': '100.00'},
        <String, dynamic>{'amount': '-40.50'},
      ]);
      expect(f.inTotal, 100);
      expect(f.outTotal, 40.50);
    });
  });
}
