import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/core/providers.dart';
import 'package:iakauntan/src/core/theme.dart';
import 'package:iakauntan/src/features/banking/reconciliation_history_dialog.dart';

/// The reconciliation register.
///
/// The rules are asserted in `supabase/tests/bank_reconciliation.sql`:
/// a period cannot be closed twice or behind a closed one, and only the
/// most recent one may be reopened. What is asserted here is that the
/// register offers reopening on exactly the row the database will
/// accept, and that it names a phantom if it ever meets one.
void main() {
  Map<String, dynamic> rec(
    String id,
    String date, {
    int lines = 1,
    bool canReopen = false,
    String? who = 'Demo User',
  }) => {
    'id': id,
    'bank_account': 'Maybank current',
    'statement_date': date,
    'statement_balance': 1000.0,
    'book_balance': 1000.0,
    'difference': 0.0,
    'lines': lines,
    'completed_at': '2026-05-01T09:00:00Z',
    'completed_by': who,
    'can_reopen': canReopen,
  };

  // -------------------------------------------------------------------
  // Reading a row
  // -------------------------------------------------------------------
  test('a reconciliation over lines is not a phantom', () {
    expect(phantomReconciliation(rec('a', '2026-03-31')), isNull);
  });

  test('one that closed over nothing is named as agreeing nothing', () {
    // The shape the pre-0157 duplicate produced: the first completion
    // took every line, so the second stamped none and recorded an
    // agreement anyway.
    final said = phantomReconciliation(rec('b', '2026-03-31', lines: 0));
    expect(said, contains('agreed nothing'));
    expect(said, contains('not evidence'));
  });

  test('the summary says how many lines and who closed it', () {
    final text = reconciliationSummary(rec('a', '2026-03-31', lines: 12));
    expect(text, contains('12 statement lines'));
    expect(text, contains('Demo User'));
  });

  test('and reads singular for one line', () {
    expect(
      reconciliationSummary(rec('a', '2026-03-31')),
      contains('1 statement line'),
    );
  });

  test('a reconciliation with nobody recorded still reads', () {
    final text = reconciliationSummary(rec('a', '2026-03-31', who: null));
    expect(text, contains('1 statement line'));
    expect(text, isNot(contains('closed by')));
  });

  // -------------------------------------------------------------------
  // The register
  // -------------------------------------------------------------------
  Widget harness(
    List<Map<String, dynamic>> rows, {
    bool canPost = true,
    bool canReadLedger = true,
  }) => ProviderScope(
    overrides: [
      repoProvider.overrideWithValue(null),
      canPostProvider.overrideWithValue(canPost),
      canReadLedgerProvider.overrideWithValue(canReadLedger),
      bankReconciliationsProvider.overrideWith((ref, id) async => rows),
    ],
    child: MaterialApp(
      theme: AppTheme.light(),
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () =>
                showReconciliationHistory(context, bankAccountId: 'b1'),
            child: const Text('Open'),
          ),
        ),
      ),
    ),
  );

  Future<void> open(WidgetTester tester, Widget w) async {
    await tester.pumpWidget(w);
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
  }

  testWidgets('the register lists each reconciliation', (tester) async {
    await open(
      tester,
      harness([
        rec('r2', '2026-04-30', canReopen: true),
        rec('r1', '2026-03-31'),
      ]),
    );
    expect(find.textContaining('30/04/2026'), findsOneWidget);
    expect(find.textContaining('31/03/2026'), findsOneWidget);
  });

  testWidgets('only the most recent offers reopening', (tester) async {
    // The database refuses to reopen anything else, so offering it would
    // be a button that always fails.
    await open(
      tester,
      harness([
        rec('r2', '2026-04-30', canReopen: true),
        rec('r1', '2026-03-31'),
      ]),
    );
    expect(find.byKey(const ValueKey('reopen-r2')), findsOneWidget);
    expect(find.byKey(const ValueKey('reopen-r1')), findsNothing);
  });

  testWidgets('and nobody who cannot post is offered it at all', (
    tester,
  ) async {
    await open(
      tester,
      harness([rec('r2', '2026-04-30', canReopen: true)], canPost: false),
    );
    expect(find.byKey(const ValueKey('reopen-r2')), findsNothing);
    // The register itself still reads, which is the point of separating
    // reading the ledger from posting to it.
    expect(find.textContaining('30/04/2026'), findsOneWidget);
  });

  testWidgets('a phantom is named on the row it belongs to', (tester) async {
    await open(
      tester,
      harness([
        rec('r2', '2026-04-30', canReopen: true),
        rec('r1', '2026-03-31', lines: 0),
      ]),
    );
    expect(find.byKey(const ValueKey('phantom-r1')), findsOneWidget);
    expect(find.byKey(const ValueKey('phantom-r2')), findsNothing);
  });

  testWidgets('an account never reconciled says so', (tester) async {
    await open(tester, harness(const []));
    expect(find.textContaining('never been reconciled'), findsOneWidget);
  });
}
