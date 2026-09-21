import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/features/documents/doc_types.dart';
import 'package:iakauntan/src/features/documents/transfer.dart';

/// The rules the transfer menu offers, which have to be the same rules
/// `app.transfer_counter` enforces in migration 0081.
///
/// If they drift, the menu offers a transfer the database will refuse —
/// and the user finds out by pressing the button.
void main() {
  TransferLine line(String id, double qty, double taken) => TransferLine(
        lineId: id,
        lineNo: 1,
        description: 'Widget',
        quantity: qty,
        taken: taken,
        outstanding: qty - taken,
      );

  group('where a document can go', () {
    test('the sales cycle', () {
      expect(transferTargets('quotation'),
          ['sales_order', 'delivery_order', 'invoice']);
      expect(transferTargets('sales_order'), ['delivery_order', 'invoice']);
      expect(transferTargets('delivery_order'), ['invoice']);
    });

    test('the purchase cycle', () {
      expect(transferTargets('purchase_order'), ['goods_received', 'bill']);
      expect(transferTargets('goods_received'), ['bill']);
    });

    test('the ends of the chain go nowhere', () {
      for (final terminal in [
        'invoice',
        'bill',
        'credit_note',
        'debit_note',
        'purchase_credit_note',
      ]) {
        expect(transferTargets(terminal), isEmpty, reason: terminal);
        expect(canTransfer(terminal), isFalse);
      }
    });

    test('the next step in the cycle is offered first', () {
      // A quotation can jump straight to an invoice, but the ordinary
      // path is the order, and a menu that led with the shortcut would
      // make skipping the order the default.
      expect(transferTargets('quotation').first, 'sales_order');
      expect(transferTargets('purchase_order').first, 'goods_received');
    });

    test('every target is a document type the app can open', () {
      // A target with no screen would transfer successfully and then
      // navigate to nothing.
      for (final source in [
        'quotation',
        'sales_order',
        'delivery_order',
        'purchase_order',
        'goods_received',
      ]) {
        for (final target in transferTargets(source)) {
          expect(docTypes.containsKey(target), isTrue,
              reason: '$source -> $target has no editor');
        }
      }
    });
  });

  group('what may be submitted', () {
    test('everything outstanding is fine', () {
      final lines = [line('a', 10, 4)];
      expect(transferProblem(lines, {'a': 6}), isNull);
    });

    test('more than remains is refused, not clamped', () {
      final lines = [line('a', 10, 4)];
      final problem = transferProblem(lines, {'a': 7});
      expect(problem, isNotNull);
      expect(problem, contains('6'));
      expect(problem, contains('7'));
    });

    test('a negative quantity is refused', () {
      expect(transferProblem([line('a', 10, 0)], {'a': -1}), isNotNull);
    });

    test('nothing at all is refused', () {
      expect(transferProblem([line('a', 10, 0)], {'a': 0}), isNotNull);
      expect(transferProblem([line('a', 10, 0)], const {}), isNotNull);
    });

    test('one line of several is enough', () {
      final lines = [line('a', 10, 10), line('b', 5, 0)];
      expect(transferProblem(lines, {'a': 0, 'b': 5}), isNull);
    });

    test('a spent line cannot be taken again', () {
      expect(transferProblem([line('a', 10, 10)], {'a': 1}), isNotNull);
    });
  });

  /// Nothing goes forward while a signature is outstanding.
  ///
  /// `0646` is the migration; this is the sentence on the menu item.
  /// The reason it is worth a test of its own rather than being left to
  /// the database: until `0646` the approval decision was read in
  /// exactly ONE place, a trigger on the transition into `posted`, and
  /// seven of the fifteen document types never post. A rule on a
  /// purchase requisition -- the document whose only purpose is to be
  /// approved -- could be written, saved, submitted, signed and
  /// ignored.
  group('what an outstanding approval stops', () {
    Map<String, dynamic> state({
      bool required = true,
      bool approved = false,
      String? requestId,
    }) => {
      'is_required': required,
      'is_approved': approved,
      'request_id': requestId,
    };

    test('a document no rule covers goes forward', () {
      expect(transferBlockedBecause(state(required: false)), isNull);
    });

    test('and so does one that has been signed', () {
      expect(
        transferBlockedBecause(state(approved: true, requestId: 'r1')),
        isNull,
      );
    });

    test('one that needs a signature and has not been sent says so', () {
      final why = transferBlockedBecause(state());
      expect(why, isNotNull);
      expect(why, contains('approval'));
    });

    test('and one already on somebody\'s desk says something different', () {
      // Two different answers because they have two different next
      // steps: one is "press Send for approval", the other is "wait".
      // A single sentence would tell half the people the wrong thing.
      final sent = transferBlockedBecause(state(requestId: 'r1'));
      expect(sent, isNotNull);
      expect(sent, isNot(equals(transferBlockedBecause(state()))));
    });

    test('a read that has not landed does not block anything', () {
      // Null is "we do not know yet", not "no". The database refuses
      // anyway, and greying the button on a missing read would hide a
      // transfer that is perfectly allowed.
      expect(transferBlockedBecause(null), isNull);
    });

    test('and a missing key is not a requirement', () {
      // `approval_state` returns no row where the caller may not read
      // the document. A map without `is_required` must not read as
      // true.
      expect(transferBlockedBecause(const {}), isNull);
    });
  });
}
