import 'package:flutter_test/flutter_test.dart';
import 'package:iakauntan/src/features/pos/take_it_off.dart';

void main() {
  group('whether the bill is still open', () {
    test('only while it is parked', () {
      // Both functions refuse anything else, in the same words: once
      // it is tendered, where it went "is part of what was reported
      // for the day".
      expect(billIsStillOpen('parked'), isTrue);
      expect(billIsStillOpen('completed'), isFalse);
      expect(billIsStillOpen('void'), isFalse);
      expect(billIsStillOpen(null), isFalse);
    });
  });

  group('taking the delivery back', () {
    test('a parked bill whose run is still waiting', () {
      expect(
        deliveryCanBeCleared(saleStatus: 'parked', deliveryStatus: 'pending'),
        isTrue,
      );
    });

    test('not once a driver has it', () {
      // "Once a driver has it, the run happened. Whatever the shop
      // wants to record instead, it is not 'there was never a
      // delivery'."
      for (final s in ['assigned', 'collected', 'delivered', 'failed']) {
        expect(
          deliveryCanBeCleared(saleStatus: 'parked', deliveryStatus: s),
          isFalse,
          reason: s,
        );
      }
    });

    test('not once the bill has been tendered', () {
      expect(
        deliveryCanBeCleared(
          saleStatus: 'completed',
          deliveryStatus: 'pending',
        ),
        isFalse,
      );
    });

    test('a bill with no run at all is not blocked by the run', () {
      // clear_pos_delivery returns quietly when there is nothing to
      // clear, so a null status must not read as "a driver has it".
      expect(
        deliveryCanBeCleared(saleStatus: 'parked', deliveryStatus: null),
        isTrue,
      );
    });
  });

  group('why it cannot be taken back', () {
    test('nothing to say when it can', () {
      expect(
        deliveryClearBlockedBecause(
          saleStatus: 'parked',
          deliveryStatus: 'pending',
        ),
        isNull,
      );
    });

    test('the tendered bill is the reason that is checked first', () {
      // Both are true here, and the one somebody can act on is the
      // bill.
      final why = deliveryClearBlockedBecause(
        saleStatus: 'completed',
        deliveryStatus: 'collected',
      );
      expect(why, contains('tendered'));
    });

    test('and the driver, when the bill is still open', () {
      final why = deliveryClearBlockedBecause(
        saleStatus: 'parked',
        deliveryStatus: 'collected',
      );
      expect(why, contains('driver'));
      expect(why, contains('failed'));
    });
  });

  group('taking a voucher off', () {
    test('while the bill is parked', () {
      expect(promotionCanBeRemoved('parked'), isTrue);
    });

    test('not after it has been tendered', () {
      expect(promotionCanBeRemoved('completed'), isFalse);
    });
  });
}
