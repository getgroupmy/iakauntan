import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/features/stock/stock_take_screen.dart';

/// The count that left the app the moment it was posted.
///
/// `stockAdjustments` and `stockAdjustmentsProvider` both existed, and
/// the stock take screen invalidated the provider after every posted
/// count, and nothing read it. A shopkeeper saw the shelf agree with
/// the books and had no way to ask what the difference had been, or
/// whether last month's count had been posted at all.
///
/// What a stock adjustment does to the ledger is the database's
/// business and is asserted in `supabase/tests/`. Asserted here is the
/// part that only exists in Dart: that an enum reaches the shelf as
/// English, and that a missing warehouse is left out rather than
/// printed as a gap.
void main() {
  group('adjustmentKind', () {
    test('says what the count was for, in words', () {
      expect(adjustmentKind('stock_take'), 'Count');
      expect(adjustmentKind('write_off'), 'Written off');
      expect(adjustmentKind('revaluation'), 'Revalued');
      expect(adjustmentKind('opening'), 'Opening balance');
    });

    test('an unknown type is not printed raw at a shopkeeper', () {
      // A fifth value added to the check constraint one day would
      // otherwise reach the screen as `consignment_return`.
      expect(adjustmentKind('something_new'), 'Adjustment');
      expect(adjustmentKind(null), 'Adjustment');
    });
  });

  group('adjustmentSummary', () {
    Map<String, dynamic> row({
      String date = '2026-08-31',
      String? reason = 'Stock take',
    }) => {
      'adjustment_no': 'ADJ-0007',
      'adjustment_date': date,
      'warehouse_id': 'w1',
      'reason': reason,
      'adjustment_type': 'stock_take',
      'status': 'posted',
    };

    test('when, where and why', () {
      expect(
        adjustmentSummary(row(), warehouse: 'Main store'),
        '31/08/2026 · Main store · Stock take',
      );
    });

    test('a warehouse this user cannot see is omitted, not dashed', () {
      // The names come from the list the screen already holds. One it
      // does not hold is a shelf out of this user's reach, which is not
      // the same as a shelf with no name.
      expect(
        adjustmentSummary(row(), warehouse: null),
        '31/08/2026 · Stock take',
      );
      expect(
        adjustmentSummary(row(), warehouse: '  '),
        '31/08/2026 · Stock take',
      );
    });

    test('and a count saved without a reason still reads', () {
      expect(
        adjustmentSummary(row(reason: null), warehouse: 'Main store'),
        '31/08/2026 · Main store',
      );
      expect(
        adjustmentSummary(row(reason: '   '), warehouse: 'Main store'),
        '31/08/2026 · Main store',
      );
    });
  });
}
