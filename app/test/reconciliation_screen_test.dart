import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/core/providers.dart';
import 'package:iakauntan/src/core/theme.dart';
import 'package:iakauntan/src/data/repository.dart';
import 'package:iakauntan/src/features/banking/reconciliation_screen.dart';

/// Reconciling a bank account against its statement.
///
/// The two balances never agree; the question is whether every
/// difference is accounted for. Book balance, less what the bank has
/// not seen, should equal the statement -- and what is left over is the
/// number the screen shows largest.
///
/// Three decisions live only in this widget.
///
/// THE TOLERANCE. `difference.abs() < 0.005` is half a sen, which is
/// the right width for a figure carried to two places: it absorbs the
/// representation error in a sum of doubles and nothing else. Widen it
/// to a sen and a real one-sen difference -- which is a real
/// transposition somewhere -- gets a green tick.
///
/// THE SIGN OF THE UNPRESENTED LINE. It is rendered negative because it
/// is SUBTRACTED. Showing the same figure unsigned turns a subtraction
/// into what reads as an addition, and the arithmetic on the page stops
/// being checkable by the person doing the reconciling -- which is the
/// only reason to show the working at all.
///
/// AND WHAT A DIFFERENCE MEANS. "Out by RM 240" is not actionable.
/// Three named causes are: a line nobody matched, a payment entered
/// twice, a charge the books have not heard of.
void main() {
  Map<String, dynamic> status({
    double book = 12500,
    double unpresented = 340,
    double expected = 12160,
    double statement = 12160,
    double difference = 0,
    int unmatched = 0,
  }) => {
    'book_balance': book,
    'unpresented': unpresented,
    'expected_statement': expected,
    'statement_balance': statement,
    'difference': difference,
    'unmatched_lines': unmatched,
  };

  Widget wrap(Map<String, dynamic> st, {String role = 'owner', Repo? repo}) =>
      ProviderScope(
    overrides: [
      repoProvider.overrideWithValue(repo ?? _FakeRepo(st)),
      bankAccountsProvider.overrideWith(
        (ref) async => const [
          {'id': 'b1', 'name': 'Maybank Current', 'account_no': '5140 1234'},
        ],
      ),
      memberRoleProvider.overrideWith((ref) async => role),
    ],
    child: MaterialApp(
      theme: AppTheme.light(),
      home: const ReconciliationScreen(),
    ),
  );

  Future<void> show(
    WidgetTester tester,
    Map<String, dynamic> st, {
    String role = 'owner',
    double? width,
  }) async {
    if (width != null) {
      // `tester.view.physicalSize`, not `setSurfaceSize`: the latter
      // moves the render surface without moving `MediaQuery`. See
      // docs/widget-tests.md.
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = Size(width, 900);
      addTearDown(tester.view.reset);
    }
    await tester.pumpWidget(wrap(st, role: role));
    await tester.pumpAndSettle();
  }

  group('the working, so it can be checked', () {
    testWidgets('what the bank has not seen is subtracted, and looks it',
        (tester) async {
      await show(tester, status(book: 12500, unpresented: 340,
          expected: 12160, statement: 12160));

      expect(find.text('Book balance'), findsOneWidget);
      expect(find.text('RM 12,500.00'), findsOneWidget);

      // Negative, because it is taken away. Unsigned, the page reads as
      // 12,500 + 340 and stops being checkable.
      expect(find.text('Less what the bank has not seen'), findsOneWidget);
      expect(find.text('RM -340.00'), findsOneWidget);
      expect(find.textContaining('Unpresented cheques and deposits in '
          'transit'), findsOneWidget);

      // And the two the person compares: what the statement should say,
      // and what it does.
      expect(find.text('Statement should read'), findsOneWidget);
      expect(find.text('Statement says'), findsOneWidget);
      expect(find.text('RM 12,160.00'), findsNWidgets(2));
    });

    testWidgets('what the statement should say and what it says are two '
        'different rows', (tester) async {
      // Both fixtures above are reconciled, so expected and statement
      // hold the same figure -- and a row wired to the WRONG key renders
      // an identical page. That mutant survived the first run.
      //
      // This is the case somebody actually opens the screen for: the
      // two rows disagree, which is the whole point of showing both.
      await show(tester, status(book: 9000, unpresented: 1250,
          expected: 7750, statement: 7510, difference: 240, unmatched: 2));

      expect(find.text('RM 9,000.00'), findsOneWidget);
      expect(find.text('RM -1,250.00'), findsOneWidget);
      // Book less unpresented. Read from `statement_balance` instead and
      // this figure is nowhere on the page.
      expect(find.text('RM 7,750.00'), findsOneWidget);
      expect(find.text('RM 7,510.00'), findsOneWidget);
      // And the gap between them is what is shown largest.
      expect(find.text('Out by'), findsOneWidget);
      expect(find.text('RM 240.00'), findsOneWidget);
    });
  });

  group('the tolerance', () {
    testWidgets('a difference under half a sen is reconciled', (tester) async {
      // What a sum of doubles leaves behind, and nothing else.
      await show(tester, status(difference: 0.004, unmatched: 0));

      expect(find.text('Reconciled'), findsOneWidget);
      expect(find.text('Out by'), findsNothing);
      expect(find.byIcon(Icons.check_circle), findsOneWidget);
    });

    testWidgets('and half a sen exactly is not', (tester) async {
      // The boundary is `< 0.005`, so 0.005 is out. Widen this and a
      // real one-sen difference -- a transposition somewhere -- gets a
      // green tick.
      await show(tester, status(difference: 0.005, unmatched: 1));

      expect(find.text('Out by'), findsOneWidget);
      expect(find.text('Reconciled'), findsNothing);
      expect(find.byIcon(Icons.check_circle), findsNothing);
    });

    testWidgets('a difference the wrong way round is still a difference',
        (tester) async {
      // `abs()`. A statement 240 BELOW the books is exactly as
      // unreconciled as one 240 above, and a comparison without it
      // calls half of them reconciled.
      await show(tester, status(difference: -240, unmatched: 2));

      expect(find.text('Out by'), findsOneWidget);
      expect(find.text('RM -240.00'), findsOneWidget);
    });
  });

  group('what a difference means', () {
    testWidgets('it counts the unmatched lines and names the three causes',
        (tester) async {
      await show(tester, status(difference: 240, unmatched: 3));

      expect(find.textContaining('3 statement lines are still unmatched'),
          findsOneWidget);
      // "Out by RM 240" on its own tells somebody nothing they can act
      // on. These three are where it always is.
      expect(find.textContaining('a line nobody has matched'), findsOneWidget);
      expect(find.textContaining('a payment entered twice'), findsOneWidget);
      expect(find.textContaining('a charge the books have not heard of'),
          findsOneWidget);
    });

    testWidgets('and says none of it once the account is reconciled',
        (tester) async {
      // The control. The sentence is conditional, and a reconciled
      // account that still explains what a difference means is telling
      // somebody to go looking for one.
      await show(tester, status(difference: 0, unmatched: 0));

      expect(find.textContaining('still unmatched'), findsNothing);
      expect(find.textContaining('a payment entered twice'), findsNothing);
    });
  });

  group('the registers that were written and never read', () {
    testWidgets('transfers made, and the reconciliation history, are both '
        'reachable', (tester) async {
      // 0157: both of these were written by the app and had no way back
      // into it. A transfer, once made, left the app entirely.
      await show(tester, status());

      expect(find.byKey(const ValueKey('transfers-history')), findsOneWidget);
      expect(find.byKey(const ValueKey('reconciliation-history')),
          findsOneWidget);
    });

    testWidgets('and a viewer, who may not post, still sees its own history',
        (tester) async {
      await show(tester, status(), role: 'viewer');

      // The transfer register is not a posting action.
      expect(find.byKey(const ValueKey('transfers-history')), findsOneWidget);
      // Making one is.
      expect(find.byTooltip('Transfer between accounts'), findsNothing);
      expect(find.byTooltip('Import statement'), findsNothing);
    });
  });
  /// The three ways a statement gets in.
  ///
  /// `0683`. The dialog used to hand back the TEXT it was holding, and
  /// the screen parsed it on the way out. That was fine while both
  /// sources were text; a photograph is not. It comes back as rows the
  /// reader already separated, and rendering them into CSV so the text
  /// box could hold them would mean formatting every figure in order to
  /// parse it straight back -- a round trip whose only possible effect
  /// is to lose one.
  ///
  /// So the dialog now hands back the PARSE, and what this group
  /// asserts is that the paste still survives that change: the rows
  /// that reach `importBankTransactions` are the rows that were typed,
  /// in the shape `import_bank_transactions` reads, with the running
  /// balance still on them.
  group('getting a statement in', () {
    testWidgets('a photograph is offered beside the paste and the file',
        (tester) async {
      await show(tester, status());
      await tester.tap(find.byTooltip('Import statement'));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('statement-scan')), findsOneWidget);
      expect(find.text('Open a file'), findsOneWidget);
    });

    testWidgets('a pasted statement arrives as rows, balance and all',
        (tester) async {
      final repo = _FakeRepo(status());
      await tester.pumpWidget(wrap(status(), repo: repo));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Import statement'));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(TextField),
        ),
        'Date,Description,Reference,Amount,Balance\n'
        '01/09/2026,OPENING TRANSFER,REF001,1900.00,1900.00\n'
        '03/09/2026,CHQ 100123,REF002,-250.00,1650.00\n',
      );
      await tester.pumpAndSettle();

      await tester.tap(find.descendant(
        of: find.byType(AlertDialog),
        matching: find.widgetWithText(FilledButton, 'Import'),
      ));
      await tester.pumpAndSettle();

      expect(repo.imported, isNotNull);
      expect(repo.imported, hasLength(2));

      // The keys are `bank_transactions` column names, because that is
      // what `import_bank_transactions` reads them out under. Rename
      // one on either side and the import silently takes nothing.
      expect(repo.imported!.first['transaction_date'], '2026-09-01');
      expect(repo.imported!.first['amount'], 1900.00);
      expect(repo.imported!.first['running_balance'], 1900.00);

      // The withdrawal keeps its sign, and the balance that proves it
      // is still attached. Drop the balance and nothing downstream
      // complains -- the statement just imports unchecked.
      expect(repo.imported!.last['amount'], -250.00);
      expect(repo.imported!.last['running_balance'], 1650.00);
    });

    testWidgets('and the closing figure comes back off the bank, not a '
        'typed one', (tester) async {
      final repo = _FakeRepo(status());
      await tester.pumpWidget(wrap(status(), repo: repo));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Import statement'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(TextField),
        ),
        'Date,Description,Amount,Balance\n'
        '01/09/2026,OPENING,1900.00,1900.00\n',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.descendant(
        of: find.byType(AlertDialog),
        matching: find.widgetWithText(FilledButton, 'Import'),
      ));
      await tester.pumpAndSettle();

      expect(find.textContaining('1 imported'), findsOneWidget);
    });
  });

  /// The bar, at every width one is opened at.
  ///
  /// Six icon buttons and a title. No labelled text, so it is the
  /// cheapest of the app bars in this app -- which is exactly why it is
  /// worth rendering rather than assuming: 6 x 48 is 288 before the
  /// title, and a `RenderFlex` overflow IS a test failure here while a
  /// release build simply CLIPS it.
  group('the bar fits', () {
    for (final width in [1400.0, 1000.0, 800.0, 700.0, 600.0, 412.0, 360.0]) {
      testWidgets('at ${width.toInt()} wide', (tester) async {
        await show(tester, status(), width: width);

        expect(find.byType(ReconciliationScreen), findsOneWidget);
      });
    }
  });

}

/// Only what the screen asks for. Anything else throws, so a screen that
/// grows a third call fails loudly here rather than rendering a
/// reconciliation built out of empty maps.
class _FakeRepo implements Repo {
  _FakeRepo(this.status);

  final Map<String, dynamic> status;

  @override
  Future<Map<String, dynamic>> bankReconciliationStatus({
    required String bankAccountId,
    required DateTime asAt,
    required double statementBalance,
  }) async =>
      status;

  @override
  Future<List<Map<String, dynamic>>> bankStatementLines(
    String bankAccountId, {
    bool onlyOpen = false,
  }) async =>
      const [];

  /// What the last import was handed, kept so a test can read it.
  ///
  /// Null until something imports, which is itself the assertion in the
  /// case where the dialog hands back nothing at all.
  List<Map<String, dynamic>>? imported;

  @override
  Future<Map<String, dynamic>> importBankTransactions(
    String bankAccountId,
    List<Map<String, dynamic>> rows,
  ) async {
    imported = rows;
    return {
      'imported': rows.length,
      'skipped': 0,
      'balance_checks': rows.length - 1,
      'closing_balance': rows.last['running_balance'],
      'closing_date': rows.last['transaction_date'],
    };
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
        'the reconciliation screen called Repo.${invocation.memberName}, '
        'which this fake does not answer',
      );
}
