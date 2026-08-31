import 'package:flutter_test/flutter_test.dart';
import 'package:iakauntan/src/features/documents/settlement_discount.dart';

/// The receipt form in front of `allocate_with_discount`.
///
/// The terms and the arithmetic are `0385`'s. These assertions are
/// about the form agreeing with them, so a discount the ledger will
/// refuse is never offered on screen.
void main() {
  String money(double v) => 'RM ${v.toStringAsFixed(2)}';

  const open = DiscountOffer(
    deadline: null,
    discount: 0,
    payNow: 1000,
    stillOpen: false,
  );
  final live = DiscountOffer(
    deadline: DateTime(2026, 7, 20),
    discount: 20,
    payNow: 980,
    stillOpen: true,
  );
  final lapsed = DiscountOffer(
    deadline: DateTime(2026, 7, 1),
    discount: 20,
    payNow: 1000,
    stillOpen: false,
  );

  group('how the offer reads', () {
    test('terms with no discount say nothing', () {
      // The ordinary case. A line saying "no discount available" on
      // every receipt is noise pretending to be information.
      expect(describeOffer(open, money), isNull);
      expect(describeOffer(null, money), isNull);
    });

    test('one still open is an invitation', () {
      final said = describeOffer(live, money)!;
      expect(said, contains('RM 20.00'));
      expect(said, contains('20/07/2026'));
      expect(said, contains('RM 980.00 settles it'));
    });

    test('one that has lapsed is still worth saying', () {
      // Otherwise somebody keys the discounted figure off an old email
      // and the allocation is refused with nothing on screen to explain
      // it.
      final said = describeOffer(lapsed, money)!;
      expect(said, contains('ran out on 01/07/2026'));
      expect(said, contains('full RM 1000.00'));
    });
  });

  group('what the form will not send', () {
    test('an allocation of nothing', () {
      expect(
        allocationBlockedBecause(
          amount: 0,
          discount: 0,
          balance: 1000,
          offer: open,
        ),
        contains('of something'),
      );
    });

    test('a discount where the terms offer none', () {
      expect(
        allocationBlockedBecause(
          amount: 980,
          discount: 20,
          balance: 1000,
          offer: open,
        ),
        contains('credit note'),
      );
    });

    test('a discount that has run out', () {
      expect(
        allocationBlockedBecause(
          amount: 980,
          discount: 20,
          balance: 1000,
          offer: lapsed,
        ),
        contains('has run out'),
      );
    });

    test('more than the terms allow', () {
      expect(
        allocationBlockedBecause(
          amount: 950,
          discount: 50,
          balance: 1000,
          offer: live,
        ),
        contains('at most'),
      );
    });

    test('more than is owed', () {
      expect(
        allocationBlockedBecause(
          amount: 1000,
          discount: 20,
          balance: 1000,
          offer: live,
        ),
        contains('more than is owed'),
      );
    });

    test('a negative discount', () {
      expect(
        allocationBlockedBecause(
          amount: 980,
          discount: -20,
          balance: 1000,
          offer: live,
        ),
        contains('negative'),
      );
    });

    test('and the ordinary case goes through', () {
      expect(
        allocationBlockedBecause(
          amount: 980,
          discount: 20,
          balance: 1000,
          offer: live,
        ),
        isNull,
      );
      expect(
        allocationBlockedBecause(
          amount: 1000,
          discount: 0,
          balance: 1000,
          offer: open,
        ),
        isNull,
      );
    });

    test('a part payment with no discount is fine', () {
      expect(
        allocationBlockedBecause(
          amount: 400,
          discount: 0,
          balance: 1000,
          offer: open,
        ),
        isNull,
      );
    });
  });
}
