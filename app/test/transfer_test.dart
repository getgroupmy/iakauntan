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
}
