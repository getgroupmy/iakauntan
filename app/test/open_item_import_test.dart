import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/core/csv.dart';
import 'package:iakauntan/src/core/providers.dart';
import 'package:iakauntan/src/core/theme.dart';
import 'package:iakauntan/src/features/imports/import_screen.dart';

/// Bringing open invoices and bills across.
///
/// The arithmetic is asserted in `supabase/tests/open_item_import.sql` —
/// the database is what dates the ledger entry at the changeover while
/// the document keeps the day it was raised, and what refuses a file
/// with a bad row in it. What is asserted here is the screen, and two of
/// these matter more than they look.
///
/// The first is the column mapping. `outstanding_amount` is what is
/// still owed, and every alias that could plausibly be filled in with
/// the *original* total has to be kept off the map: a heading that
/// resolved 'total' to this field would overstate the receivables by
/// everything already collected, and nothing on the screen would say so.
///
/// The second is which permission the screen asks for. An open item is a
/// posting, so a screen that asked for write access throughout would
/// hand an accounts clerk an enabled button and a refusal.
void main() {
  Widget harness({bool canWrite = true, bool canPost = true}) => ProviderScope(
    overrides: [
      repoProvider.overrideWithValue(null),
      canWriteProvider.overrideWithValue(canWrite),
      canPostProvider.overrideWithValue(canPost),
    ],
    child: MaterialApp(theme: AppTheme.light(), home: const ImportScreen()),
  );

  Future<void> openInvoices(WidgetTester tester) async {
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();
    await tester.tap(find.text('Open invoices'));
    await tester.pumpAndSettle();
  }

  group('which permission the screen asks for', () {
    test('a master file needs write access and an open item needs posting', () {
      expect(importNeedsPosting(ImportKind.contacts), isFalse);
      expect(importNeedsPosting(ImportKind.items), isFalse);
      expect(importNeedsPosting(ImportKind.openInvoices), isTrue);
      expect(importNeedsPosting(ImportKind.openBills), isTrue);
    });
  });

  group('the column map', () {
    // Exercised through the same parser the screen uses, because the
    // question is what a real header row resolves to.
    Map<String, String> parsed(String csv, Map<String, List<String>> aliases) {
      final table = parseCsvTable(csv, headerMapper(aliases));
      expect(table.problems, isEmpty, reason: 'the fixture must parse');
      return table.rows.single;
    }

    test('an outstanding balance is recognised under the names a '
        'spreadsheet gives it', () {
      final row = parsed(
        'Invoice No,Customer Code,Invoice Date,Balance Due\n'
        'INV-1,C-001,2025-11-03,3000',
        openInvoiceColumns,
      );
      expect(row['doc_no'], 'INV-1');
      expect(row['contact_code'], 'C-001');
      expect(row['doc_date'], '2025-11-03');
      expect(row['outstanding_amount'], '3000');
    });

    test('and a column called total is not', () {
      // The whole point. A file exported with the original invoice total
      // must not silently become the amount owed — the row is dropped as
      // unrecognised and the database then refuses it for having no
      // outstanding amount, which is a sentence somebody can act on.
      final table = parseCsvTable(
        'Invoice No,Customer Code,Invoice Date,Total\n'
        'INV-1,C-001,2025-11-03,5000',
        headerMapper(openInvoiceColumns),
      );
      expect(table.rows.single.containsKey('outstanding_amount'), isFalse);
    });

    test('a bill keeps our reference and the supplier’s apart', () {
      final row = parsed(
        'Our Ref,Supplier Invoice No,Supplier Code,Bill Date,Outstanding\n'
        'BILL-77,ST-2026-4411,S-001,2026-05-02,800',
        openBillColumns,
      );
      expect(row['doc_no'], 'BILL-77');
      expect(row['supplier_doc_no'], 'ST-2026-4411');
      expect(row['contact_code'], 'S-001');
    });
  });

  testWidgets('the changeover date is asked for, and only where it means '
      'something', (tester) async {
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();

    // A contact list has no ledger date.
    expect(find.byKey(const ValueKey('import-as-at')), findsNothing);
    expect(find.text('Changeover date'), findsNothing);

    await tester.tap(find.text('Open invoices'));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('import-as-at')), findsOneWidget);
    expect(find.text('Changeover date'), findsOneWidget);
    expect(
      find.textContaining('Every ledger entry in this file carries it'),
      findsOneWidget,
    );
  });

  testWidgets('the screen says what the amount column is, because that is '
      'the mistake it exists to stop', (tester) async {
    await openInvoices(tester);

    expect(find.textContaining('what is still owed'), findsOneWidget);
    expect(find.textContaining('not the original total'), findsOneWidget);
    // And the two decisions somebody would otherwise be surprised by.
    expect(find.textContaining('the date it was raised'), findsOneWidget);
    expect(find.textContaining('No tax is posted'), findsOneWidget);
  });

  testWidgets('the required columns are the ones the database insists on', (
    tester,
  ) async {
    await openInvoices(tester);

    for (final field in [
      'doc_no',
      'contact_code',
      'doc_date',
      'outstanding_amount',
    ]) {
      expect(find.text(field), findsOneWidget, reason: '$field is offered');
    }
    // The control: a field the master-file importers use is not on this
    // list, so 'every chip is present' cannot pass by accident.
    expect(find.text('credit_limit'), findsNothing);
  });

  testWidgets('nothing can be written before it has been checked', (
    tester,
  ) async {
    await openInvoices(tester);

    final button = tester.widget<FilledButton>(
      find.byKey(const ValueKey('import-commit')),
    );
    expect(
      button.onPressed,
      isNull,
      reason:
          'the file has not been previewed, and the import would refuse '
          'it anyway',
    );
  });

  testWidgets('switching what is being imported clears the previous answer', (
    tester,
  ) async {
    // Otherwise a verdict about a contact list stays on screen above a
    // box that now holds invoices, and reads as though it were about
    // them.
    await openInvoices(tester);
    await tester.enterText(
      find.byType(TextField),
      'doc_no\nINV-1', // enough to make the parser complain
    );
    await tester.tap(find.text('Contacts'));
    await tester.pumpAndSettle();

    expect(find.textContaining('could not be read'), findsNothing);
    expect(find.byKey(const ValueKey('import-as-at')), findsNothing);
  });
}
