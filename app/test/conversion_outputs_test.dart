import 'package:flutter_test/flutter_test.dart';
import 'package:iakauntan/src/features/stock/conversion_outputs.dart';

/// A chicken, as `supabase/tests/stock_transfers.sql` cuts one up:
/// forty per cent to the breast, thirty-five to two thighs, twenty-five
/// to the wings.
List<Map<String, dynamic>> theBird() => [
  {
    'line_no': 1,
    'item_name': 'Dada ayam',
    'quantity': 1,
    'uom_code': 'PCE',
    'cost_share': 40,
  },
  {
    'line_no': 2,
    'item_name': 'Peha ayam',
    'quantity': 2,
    'uom_code': 'PCE',
    'cost_share': 35,
  },
  {
    'line_no': 3,
    'item_name': 'Kepak ayam',
    'quantity': 2,
    'uom_code': 'PCE',
    'cost_share': 25,
  },
];

void main() {
  group('how many times', () {
    test('a count is what somebody typed', () {
      expect(timesOf('3'), 3);
      expect(timesOf(' 2.5 '), 2.5);
      expect(timesOf('1,000'), 1000);
    });

    test('and nothing at all is not one', () {
      // The dialog used to read `num.tryParse(text) ?? 1`, so a typo
      // quietly cut up one chicken.
      expect(timesOf('abc'), isNull);
      expect(timesOf(''), isNull);
    });

    test('none of it is a refusal the server would make', () {
      expect(timesOf('0'), isNull);
      expect(timesOf('-2'), isNull);
    });
  });

  group('what a run takes and makes', () {
    test('twice the chicken is twice the pieces', () {
      expect(consumedQuantity(fromQuantity: 1, times: 2), 2);
      expect(producedQuantity(theBird()[1], 2), 4);
    });

    test('a fraction of a run is a fraction of everything', () {
      expect(consumedQuantity(fromQuantity: 2.5, times: 0.5), 1.25);
      expect(producedQuantity(theBird()[0], 0.5), 0.5);
    });

    test('and it is rounded where the column rounds it', () {
      // 0.1 * 3 is 0.30000000000000004 in a double, and the column
      // holds six places.
      expect(consumedQuantity(fromQuantity: 0.1, times: 3), 0.3);
      expect(
        producedQuantity({'quantity': 1, 'cost_share': 1}, 1 / 3),
        0.333333,
      );
    });

    test('an output nobody gave a quantity makes nothing', () {
      expect(producedQuantity({'uom_code': 'PCE'}, 5), 0);
      expect(producedQuantity({'quantity': null}, 5), 0);
    });
  });

  group('the split', () {
    test('comes to the whole bird and no more', () {
      expect(declaredShare(theBird()), 100);
    });

    test('and is worth reading when it does not', () {
      final drifted = theBird()..removeLast();
      expect(declaredShare(drifted), 75);
    });

    test('nothing at all shares nothing', () {
      expect(declaredShare(const []), 0);
    });

    test('and an output with no share on it adds none', () {
      expect(declaredShare([theBird()[0], const {'item_name': 'Skin'}]), 40);
    });
  });

  group('why it cannot be run', () {
    test('a switched-off conversion is refused in the server words', () {
      expect(
        conversionBlockedBecause(isActive: false, times: 3),
        'That conversion has been switched off.',
      );
    });

    test('and so is a count that is not a count', () {
      expect(
        conversionBlockedBecause(isActive: true, times: null),
        'How many times?',
      );
    });

    test('being switched off is said first', () {
      // Both are wrong; the one that cannot be fixed by typing is the
      // one worth saying.
      expect(
        conversionBlockedBecause(isActive: false, times: null),
        'That conversion has been switched off.',
      );
    });

    test('an active conversion and a real count is not blocked', () {
      expect(conversionBlockedBecause(isActive: true, times: 1), isNull);
    });
  });

  group('whether the store looks like it holds enough', () {
    test('it does not when there is less than the run needs', () {
      expect(looksShortInTheStore(onHand: 3, needed: 4), isTrue);
    });

    test('exactly enough is enough', () {
      expect(looksShortInTheStore(onHand: 4, needed: 4), isFalse);
    });

    test('and more than enough is enough', () {
      expect(looksShortInTheStore(onHand: 40, needed: 4), isFalse);
    });
  });

  group('the line one output reads as', () {
    test('names how many come out and what share they carry', () {
      expect(
        outputLine(theBird()[1], 3),
        '6 PCE · 35% of what it was worth',
      );
    });

    test('a share with a fraction keeps it', () {
      expect(
        outputLine({
          'quantity': 1,
          'uom_code': 'KGM',
          'cost_share': 12.5,
        }, 1),
        '1 KGM · 12.5% of what it was worth',
      );
    });
  });
}
