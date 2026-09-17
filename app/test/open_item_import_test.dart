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
  /// The progress card reads the database, so every harness needs an
  /// answer for it. Empty by default: these tests are about the
  /// importers, and the card has its own group at the bottom.
  Widget harness({
    bool canWrite = true,
    bool canPost = true,
    List<Map<String, dynamic>> progress = const [],
  }) => ProviderScope(
    overrides: [
      repoProvider.overrideWithValue(null),
      canWriteProvider.overrideWithValue(canWrite),
      canPostProvider.overrideWithValue(canPost),
      migrationProgressProvider.overrideWith((ref) async => progress),
    ],
    child: MaterialApp(theme: AppTheme.light(), home: const ImportScreen()),
  );

  Map<String, dynamic> step(int no, String name, num qty, String detail) => {
    'step_no': no,
    'step': name,
    'quantity': qty,
    'detail': detail,
  };

  Future<void> openInvoices(WidgetTester tester) async {
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();
    // `ensureVisible` first, like `openBalances` below. This used to
    // tap directly, and it worked only because 'Open invoices' was the
    // third of six segments and happened to fit an 800-pixel surface.
    // 0550 added a seventh -- the chart of accounts, ahead of it -- and
    // pushed it off the end, at which point the tap landed on nothing
    // silently and both assertions came back "found 0 widgets".
    await tester.ensureVisible(find.text('Open invoices'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Open invoices'));
    await tester.pumpAndSettle();
  }

  /// The last segment does not fit an 800-pixel test surface, so it sits
  /// off the end of the row's horizontal scroll and a tap lands on
  /// nothing — silently, which is why both assertions that used it came
  /// back "found 0 widgets" rather than an error about the tap.
  Future<void> openBalances(WidgetTester tester) async {
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Opening balances'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Opening balances'));
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

    await tester.ensureVisible(find.text('Open invoices'));
    await tester.pumpAndSettle();
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
    // And back again. Scrolling to 'Open invoices' above moved the row,
    // so the first segment is now off the other end.
    await tester.ensureVisible(find.text('Contacts'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Contacts'));
    await tester.pumpAndSettle();

    expect(find.textContaining('could not be read'), findsNothing);
    expect(find.byKey(const ValueKey('import-as-at')), findsNothing);
  });

  group('the opening trial balance', () {
    test('it posts, so it asks for posting rights like the open items do', () {
      expect(importNeedsPosting(ImportKind.openingBalances), isTrue);
    });

    test('a warning does not stop the file and an error does', () {
      // The rule that makes the control-account comparison usable. A
      // receivables total that disagrees with the invoices brought
      // across is a warning: the difference is exactly what Opening
      // Balance Equity is then left holding, and refusing the file would
      // make the most informative case the one nobody can import.
      expect(
        importBlockingErrors([
          {'status': 'ok'},
          {'status': 'warning'},
          {'status': 'imported'},
        ]),
        0,
      );
      expect(
        importBlockingErrors([
          {'status': 'warning'},
          {'status': 'error'},
        ]),
        1,
      );
    });

    test('debit and credit stay two columns, under the names a trial '
        'balance uses', () {
      // Collapsing them into one signed amount is asking somebody to get
      // a sign wrong, and no trial balance anybody exports is shaped
      // that way.
      final table = parseCsvTable(
        'Account,Dr,Cr\n1110,5000.00,\n3100,,5000.00',
        headerMapper(openingBalanceColumns),
      );
      expect(table.problems, isEmpty);
      expect(table.rows.first['account_code'], '1110');
      expect(table.rows.first['debit'], '5000.00');
      expect(table.rows.last['credit'], '5000.00');
    });

    testWidgets('the screen says the control accounts are compared rather '
        'than posted again', (tester) async {
      await openBalances(tester);

      expect(find.textContaining('not posted again'), findsOneWidget);
      expect(find.textContaining('comes to zero'), findsOneWidget);
      // And not the open-item copy, which is about a different file and
      // would be actively misleading here.
      expect(find.textContaining('what is still owed'), findsNothing);
    });

    testWidgets('it asks for the account code, not a document number', (
      tester,
    ) async {
      await openBalances(tester);

      expect(find.text('account_code'), findsOneWidget);
      expect(find.text('debit'), findsOneWidget);
      expect(find.text('credit'), findsOneWidget);
      expect(find.text('outstanding_amount'), findsNothing);
      // It still posts, so the changeover date is still asked for.
      expect(find.byKey(const ValueKey('import-as-at')), findsOneWidget);
    });
  });

  group('opening stock', () {
    test('it sets the cost every later sale is charged at, so it asks for '
        'posting rights too', () {
      expect(importNeedsPosting(ImportKind.openingStock), isTrue);
    });

    test('a quantity and a cost per unit, not a total value', () {
      // A total divided back out by a quantity somebody typed is one
      // rounding away from a margin that drifts, so `unit_cost` is the
      // field and 'value' is deliberately not an alias for it.
      final table = parseCsvTable(
        'Item,Qty,Average Cost\nWIDGET,100,10.00',
        headerMapper(openingStockColumns),
      );
      expect(table.problems, isEmpty);
      final row = table.rows.single;
      expect(row['item_code'], 'WIDGET');
      expect(row['quantity'], '100');
      expect(row['unit_cost'], '10.00');
    });

    test('a batch or a serial arrives under either name', () {
      for (final heading in ['Batch No', 'Serial No']) {
        final row = parseCsvTable(
          'Item,Qty,Cost,$heading\nBATCHY,40,25,B-1',
          headerMapper(openingStockColumns),
        ).rows.single;
        expect(row['lot_no'], 'B-1', reason: '$heading maps to lot_no');
      }
    });

    testWidgets('the screen says no journal is posted, and why', (
      tester,
    ) async {
      await tester.pumpWidget(harness());
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Opening stock'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Opening stock'));
      await tester.pumpAndSettle();

      expect(find.textContaining('No journal is posted'), findsOneWidget);
      expect(find.textContaining('would double it'), findsOneWidget);
      expect(find.text('item_code'), findsOneWidget);
      expect(find.text('unit_cost'), findsOneWidget);
      // Not the trial balance's copy, and not the open items'.
      expect(find.textContaining('comes to zero'), findsNothing);
      expect(find.textContaining('what is still owed'), findsNothing);
    });
  });

  group('where the migration has got to', () {
    List<Map<String, dynamic>> upTo(String verdict, {num suspense = 0}) => [
      step(1, 'Customers and suppliers', 12, 'Everything else names them.'),
      step(2, 'Items', 0, 'Only needed if you sell stock.'),
      step(3, 'Open invoices', 40, 'What customers still owed.'),
      step(4, 'Open bills', 7, 'What was still owed to suppliers.'),
      step(5, 'Opening trial balance', 0, 'Brought in once.'),
      step(6, 'Opening stock', 0, 'Posts no journal.'),
      step(7, 'Opening Balance Equity', suspense, verdict),
    ];

    testWidgets('the six steps are listed in the order they have to be done', (
      tester,
    ) async {
      await tester.pumpWidget(harness(progress: upTo('still to come')));
      await tester.pumpAndSettle();

      // Scoped to the card: several step names are also headings or
      // segment labels elsewhere on the screen, so an unscoped finder
      // would be asking a different question.
      Finder inCard(String text) => find.descendant(
        of: find.byKey(const ValueKey('migration-progress')),
        matching: find.text(text),
      );

      for (final name in [
        'Customers and suppliers',
        'Items',
        'Open invoices',
        'Open bills',
        'Opening trial balance',
        'Opening stock',
      ]) {
        expect(inCard(name), findsOneWidget, reason: '$name is a step');
      }
      // Counts, not ticks: nothing on this card claims a step with
      // nothing in it is unfinished, because for a services firm it is
      // not.
      expect(inCard('12'), findsOneWidget);
      expect(inCard('40'), findsOneWidget);
      expect(inCard('0'), findsNWidgets(3));
    });

    testWidgets('an unfinished migration is not ticked, even at nil', (
      tester,
    ) async {
      // The case a naive card gets wrong: a company that has brought
      // nothing across also reads nil, and congratulating them would be
      // the worst possible answer.
      await tester.pumpWidget(
        harness(progress: upTo('Nothing has been brought across yet.')),
      );
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.pending_outlined), findsOneWidget);
      expect(find.byIcon(Icons.check_circle_outline), findsNothing);
      expect(
        find.textContaining('Nothing has been brought across yet'),
        findsOneWidget,
      );
    });

    testWidgets('and a finished one is', (tester) async {
      await tester.pumpWidget(
        harness(
          progress: upTo(
            'Nil, which means everything from the old books is here.',
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.check_circle_outline), findsOneWidget);
      expect(find.byIcon(Icons.pending_outlined), findsNothing);
    });

    testWidgets('the amount left is shown as money, not as a count', (
      tester,
    ) async {
      // It is a balance, and the six lines above it are quantities. The
      // same formatting for both would read as 3,400 invoices.
      await tester.pumpWidget(
        harness(
          progress: upTo(
            'A credit balance: the trial balance is still to '
            'come.',
            suspense: 3400.5,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('migration-verdict')), findsOneWidget);
      expect(find.textContaining('3,400.50'), findsOneWidget);
    });
  });
}
