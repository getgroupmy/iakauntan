import 'package:flutter_test/flutter_test.dart';
import 'package:iakauntan/src/features/documents/document_editor.dart';

Map<String, dynamic> note({num balance = 1000, String no = 'DEP-0001'}) =>
    <String, dynamic>{
      'deposit_id': 'd-$no',
      'deposit_no': no,
      'kind': 'customer',
      'amount': balance,
      'balance': balance,
    };

void main() {
  group('what a party has on deposit', () {
    test('is the sum of what is left, not what was taken', () {
      // deposits_held_for returns only open notes with a balance, so
      // the sum is what could still be set against this document.
      expect(
        depositsHeldTotal([
          note(balance: 1000),
          note(balance: 250.50, no: 'DEP-0002'),
        ]),
        1250.50,
      );
    });

    test('nothing held is nothing', () {
      expect(depositsHeldTotal(const []), 0);
    });

    test('rounds to the sen', () {
      expect(
        depositsHeldTotal([note(balance: 0.1), note(balance: 0.2)]),
        0.30,
      );
    });

    test('balances that arrive as strings still add up', () {
      expect(
        depositsHeldTotal([
          <String, dynamic>{'balance': '1000.00'},
          <String, dynamic>{'balance': '250.50'},
        ]),
        1250.50,
      );
    });
  });

  group('how it reads on the banner', () {
    test('one deposit is named as one', () {
      expect(depositsHeldLabel([note(balance: 1200)]), 'RM 1,200.00 held on deposit');
    });

    test('several are counted', () {
      // Two deposits and one of twice the size settle differently:
      // each note is applied on its own, and a single figure would
      // have somebody expecting one action.
      final s = depositsHeldLabel([
        note(balance: 600),
        note(balance: 600, no: 'DEP-0002'),
      ]);
      expect(s, contains('RM 1,200.00'));
      expect(s, contains('2 deposits'));
    });
  });
}
