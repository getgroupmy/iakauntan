import 'package:flutter_test/flutter_test.dart';
import 'package:iakauntan/src/features/stock/transfers_screen.dart';

void main() {
  group('transferState', () {
    test('says where it has got to, not what column it is in', () {
      expect(transferState('draft'), 'Being written');
      expect(transferState('sent'), 'On its way');
      expect(transferState('received'), 'Arrived');
      expect(transferState('cancelled'), 'Cancelled');
    });

    test('and passes an unknown one through rather than inventing a word', () {
      expect(transferState('something_else'), 'something_else');
    });
  });

  group('transferSummary', () {
    test('is where to where, how much, and what it is worth', () {
      expect(
        transferSummary({
          'from_warehouse': 'Central kitchen',
          'to_warehouse': 'The shop',
          'line_count': 3,
          'value': 80,
          'shortfall': 0,
        }),
        'Central kitchen → The shop · 3 lines · RM 80.00',
      );
    });

    test('singular for one line, because a list that says 1 lines reads wrong',
        () {
      expect(
        transferSummary({
          'from_warehouse': 'A',
          'to_warehouse': 'B',
          'line_count': 1,
          'value': 4,
          'shortfall': 0,
        }),
        'A → B · 1 line · RM 4.00',
      );
    });

    test('mentions a shortfall only when there is one', () {
      expect(
        transferSummary({
          'from_warehouse': 'A',
          'to_warehouse': 'B',
          'line_count': 1,
          'value': 40,
          'shortfall': 4,
        }),
        'A → B · 1 line · RM 40.00 · short by RM 4.00',
      );
    });
  });

  group('shareTotal', () {
    test('a hundred is the only total that is right', () {
      final r = shareTotal([
        {'share': 40},
        {'share': 35},
        {'share': 25},
      ]);
      expect(r.ok, isTrue);
      expect(r.total, 100);
    });

    test('and says what it actually came to when it is not', () {
      final r = shareTotal([
        {'share': 40},
        {'share': 35},
      ]);
      expect(r.ok, isFalse);
      expect(r.total, 75);
    });

    test('over a hundred is wrong too, not just under', () {
      expect(shareTotal([
        {'share': 60},
        {'share': 60},
      ]).ok, isFalse);
    });

    test('nothing at all is not a hundred', () {
      expect(shareTotal(const []).ok, isFalse);
    });

    test('a missing share counts as none rather than throwing', () {
      final r = shareTotal([
        {'share': 100},
        {'item': 'x'},
      ]);
      expect(r.total, 100);
      expect(r.ok, isTrue);
    });
  });
}
