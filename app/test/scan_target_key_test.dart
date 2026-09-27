import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/features/smartscan/scan_destination.dart';

/// The `module.action` key a destination has on the server.
///
/// Reported with two screenshots: somebody pressed Upload inside the
/// bank statement importer, beside a named bank account, and got back
/// "Nothing on that document read as statement lines" over a statement
/// that was perfectly legible.
///
/// There is no ambiguity in that press. They said what the document is
/// and where it goes — and the reader was still handed seven
/// destinations and asked to pick, because the `ocr` function took
/// `org_id`, `attachment_id` and `provider` and nothing else. A
/// statement classified as anything else comes back with `rows` null,
/// and `rows` is the only place statement lines can be.
///
/// So a screen that knows now says so. This is the table that carries
/// it, and the assertions below are all about it staying in step with
/// `destinationFromTarget`, which is the table pointing the other way.
/// Two tables of the same facts is two tables that drift, and the
/// failure when they do is silent: a key that no longer matches
/// anything on the server WIDENS back to every target (by design, in
/// `narrowToTarget`) — so the scan still works, the hint is simply
/// ignored, and nobody finds out for a year.
void main() {
  group('every destination round-trips through its key', () {
    test('there and back again', () {
      for (final d in ScanDestination.values) {
        if (d == ScanDestination.unknown) continue;
        final key = d.targetKey;
        expect(key, isNotNull, reason: '$d has no target key');
        expect(
          destinationFromTarget(key),
          d,
          reason: '$d came back as ${destinationFromTarget(key)}',
        );
      }
    });

    test('and "not sure yet" has no key at all', () {
      // Naming it would narrow the reader to a destination that does
      // not exist on the server, which `narrowToTarget` treats as
      // unknown and widens back from — the right outcome reached by
      // the wrong route. Better not to send one.
      expect(ScanDestination.unknown.targetKey, isNull);
    });

    test('no two destinations share a key', () {
      final keys = ScanDestination.values
          .map((d) => d.targetKey)
          .whereType<String>()
          .toList();
      expect(keys.toSet().length, keys.length);
    });
  });

  /// The keys themselves, spelled out once.
  ///
  /// Not derived from the enum — that would assert the code against
  /// itself. These are the `module_code || '.' || action` values in
  /// `scan_targets`, and `supabase/tests/scan_targets.sql` holds the
  /// same list on the database's side.
  group('the keys are what the database calls them', () {
    test('the seven', () {
      expect(ScanDestination.bill.targetKey, 'purchases.bill');
      expect(ScanDestination.purchaseOrder.targetKey,
          'purchases.purchase_order');
      expect(ScanDestination.goodsReceived.targetKey,
          'purchases.goods_received');
      expect(ScanDestination.invoice.targetKey, 'sales.invoice');
      expect(ScanDestination.expense.targetKey, 'accounting.expense');
      expect(ScanDestination.bankStatement.targetKey,
          'accounting.bank_statement');
      expect(ScanDestination.contact.targetKey, 'contacts.contact');
    });

    test('and a bank statement is the one the importer sends', () {
      // The reported case. `0683` gave this target its five columns and
      // `0682` marked it `repeats`, so narrowing to it is what puts
      // `rows` in the schema — which is the only reason a statement
      // can come back as lines rather than as a bill with nothing on
      // it.
      expect(ScanDestination.bankStatement.targetKey,
          'accounting.bank_statement');
      expect(ScanDestination.bankStatement.table, 'bank_transactions');
    });
  });
}
