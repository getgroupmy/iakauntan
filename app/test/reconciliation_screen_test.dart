import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/core/providers.dart';
import 'package:iakauntan/src/core/searchable_picker.dart';
import 'package:iakauntan/src/core/theme.dart';
import 'package:iakauntan/src/data/models.dart';
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
    // Null rather than 0 by default, so every test written before
    // `0716` goes on describing a server that does not send these.
    int? postedEntries,
    String? booksStart,
  }) => {
    'book_balance': book,
    'unpresented': unpresented,
    'expected_statement': expected,
    'statement_balance': statement,
    'difference': difference,
    'unmatched_lines': unmatched,
    if (postedEntries != null) 'posted_entries': postedEntries,
    if (booksStart != null) 'books_start': booksStart,
  };

  const oneBank = [
    {'id': 'b1', 'name': 'Maybank Current', 'account_no': '5140 1234'},
  ];

  // Enough of a chart of accounts for the posting dialog to offer
  // something. The heading is here on purpose: `accountPickerOptions`
  // drops it, and a fixture without one could not show that.
  final someAccounts = [
    Account(id: 'a-head', code: '6000', name: 'EXPENSES',
        accountType: 'expense', accountSubtype: 'operating_expense',
        isGroup: true),
    Account(id: 'a-rent', code: '6200', name: 'Rental',
        accountType: 'expense', accountSubtype: 'operating_expense'),
    Account(id: 'a-sales', code: '4100', name: 'Sales',
        accountType: 'revenue', accountSubtype: 'sales'),
  ];

  Widget wrap(
    Map<String, dynamic> st, {
    String role = 'owner',
    Repo? repo,
    List<Map<String, dynamic>> banks = oneBank,
    String? openAccountId,
    bool openImport = false,
  }) => ProviderScope(
    overrides: [
      repoProvider.overrideWithValue(repo ?? _FakeRepo(st)),
      bankAccountsProvider.overrideWith((ref) async => banks),
      accountsProvider.overrideWith((ref) async => someAccounts),
      memberRoleProvider.overrideWith((ref) async => role),
    ],
    child: MaterialApp(
      theme: AppTheme.light(),
      home: ReconciliationScreen(
        openAccountId: openAccountId,
        openImport: openImport,
      ),
    ),
  );

  Future<void> show(
    WidgetTester tester,
    Map<String, dynamic> st, {
    String role = 'owner',
    double? width,
    Repo? repo,
    List<Map<String, dynamic>> banks = oneBank,
    String? openAccountId,
    bool openImport = false,
  }) async {
    if (width != null) {
      // `tester.view.physicalSize`, not `setSurfaceSize`: the latter
      // moves the render surface without moving `MediaQuery`. See
      // docs/widget-tests.md.
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = Size(width, 900);
      addTearDown(tester.view.reset);
    }
    await tester.pumpWidget(wrap(
      st,
      role: role,
      repo: repo,
      banks: banks,
      openAccountId: openAccountId,
      openImport: openImport,
    ));
    await tester.pumpAndSettle();
  }

  _theEmptyLedger();

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

  group('an empty ledger, on the screen', () {
    testWidgets('says so, instead of naming three causes that do not apply',
        (tester) async {
      // The reported figures, to the sen.
      await show(tester, status(book: 0, unpresented: 0, expected: 0,
          statement: 11008.23, difference: -11008.23, unmatched: 24,
          postedEntries: 0, booksStart: '2026-01-02'));

      expect(find.textContaining('nothing for the statement to agree with'),
          findsOneWidget);
      expect(find.textContaining('02/01/2026'), findsOneWidget);
      expect(find.textContaining('a line nobody has matched'), findsNothing);
    });

    testWidgets('and nothing subtracted is not shown as minus nothing',
        (tester) async {
      // "RM -0.00" on the row above the difference reads as a figure
      // somebody should go and look at. It is zero.
      await show(tester, status(book: 0, unpresented: 0, expected: 0,
          statement: 11008.23, difference: -11008.23, unmatched: 24,
          postedEntries: 0));

      expect(find.text('RM -0.00'), findsNothing);
      // Book balance, what the bank has not seen, and what the
      // statement should therefore read: three zeroes and no minus.
      expect(find.text('RM 0.00'), findsNWidgets(3));
    });
  });

  group('posting a line that was never entered', () {
    final oneLine = [
      {
        'id': 'line-1',
        'transaction_date': '2025-10-31',
        'description': 'FPX PAYMENT',
        'amount': -10000.0,
        'is_reconciled': false,
      },
    ];

    testWidgets('an unmatched line offers it', (tester) async {
      final repo = _FakeRepo(status(difference: -10000, unmatched: 1,
          postedEntries: 0))
        ..lines = oneLine;
      await show(tester, status(), repo: repo);

      expect(find.byIcon(Icons.post_add), findsOneWidget);
    });

    testWidgets('a line already matched does not', (tester) async {
      // It has a journal. A second one would double the figure, which
      // the database refuses -- so the button would be a refusal with
      // a nicer icon.
      final repo = _FakeRepo(status())
        ..lines = [
          {...oneLine.first, 'is_reconciled': true,
            'matched_table': 'gl_entries'},
        ];
      await show(tester, status(), repo: repo);

      expect(find.byIcon(Icons.post_add), findsNothing);
      expect(find.byIcon(Icons.close), findsOneWidget);
    });

    testWidgets('and somebody who cannot post is offered neither',
        (tester) async {
      final repo = _FakeRepo(status())..lines = oneLine;
      await show(tester, status(), repo: repo, role: 'viewer');

      expect(find.byIcon(Icons.post_add), findsNothing);
    });

    testWidgets('the dialog says which way round the posting goes',
        (tester) async {
      final repo = _FakeRepo(status())..lines = oneLine;
      await show(tester, status(), repo: repo);

      // Below the fold on a test surface: tapping without this hits
      // nothing and the dialog never opens.
      await tester.ensureVisible(find.byIcon(Icons.post_add));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.post_add));
      await tester.pumpAndSettle();

      expect(find.text('Post this line'), findsOneWidget);
      // Money out: the chosen account is debited. Getting this backwards
      // files a month of spending as income.
      expect(find.textContaining('debited'), findsOneWidget);
      // The line's own description, ready to be kept or changed.
      expect(find.widgetWithText(TextField, 'FPX PAYMENT'), findsOneWidget);
      // And nothing posts until an account is chosen.
      expect(
        tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Post'))
            .onPressed,
        isNull,
      );
      expect(repo.posted, isNull);
    });

    testWidgets('choosing an account posts the line against it',
        (tester) async {
      final repo = _FakeRepo(status())..lines = oneLine;
      await show(tester, status(), repo: repo);

      await tester.ensureVisible(find.byIcon(Icons.post_add));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.post_add));
      await tester.pumpAndSettle();

      // Scoped to the dialog: the screen behind it has an account
      // picker of its own, and an unscoped finder matches both.
      await tester.tap(find.descendant(
        of: find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(SearchablePicker<String>),
        ),
        matching: find.byType(TextFormField),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      // The heading is not on offer: a group account cannot receive a
      // posting, so listing it would be listing a refusal.
      expect(find.textContaining('6000 — EXPENSES'), findsNothing);
      await tester.tap(find.text('6200 — Rental').last);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      await tester.tap(find.widgetWithText(FilledButton, 'Post'));
      await tester.pumpAndSettle();

      expect(repo.posted, {
        'transactionId': 'line-1',
        'accountId': 'a-rent',
        // The line's own wording, carried through untouched.
        'description': 'FPX PAYMENT',
      });
    });

    testWidgets('and backing out of it posts nothing', (tester) async {
      final repo = _FakeRepo(status())..lines = oneLine;
      await show(tester, status(), repo: repo);

      await tester.ensureVisible(find.byIcon(Icons.post_add));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.post_add));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(repo.posted, isNull);
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
    // `0694` moved photographing a statement into AI SmartScan, which
    // is the one door scanning has now. What arrives here is the
    // READING, parked, because a route cannot carry an
    // `OcrExtraction` — so this screen keeps the paste and the file and
    // has no camera of its own.
    testWidgets('the file and the paste stay, and the camera has gone',
        (tester) async {
      await show(tester, status());
      await tester.tap(find.byTooltip('Import statement'));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('statement-scan')), findsNothing);
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

  /// What the Bank statements screen hands over, and what happens to it.
  ///
  /// `/reconcile?account=<id>&import=1`. Both halves are load-bearing
  /// and both fail SILENTLY: drop the account and a statement is
  /// imported, successfully, into whichever bank sorts first; drop the
  /// import and somebody who pressed "Upload" arrives at a screen with
  /// an unlabelled icon, which is the thing the new screen exists to
  /// stop happening.
  group('arriving from Bank statements', () {
    const twoBanks = [
      {'id': 'b1', 'name': 'Maybank Current'},
      {'id': 'b2', 'name': 'CIMB Savings'},
    ];

    testWidgets('opens on the account that was asked for', (tester) async {
      final repo = _FakeRepo(status());
      await show(
        tester,
        status(),
        repo: repo,
        banks: twoBanks,
        openAccountId: 'b2',
      );

      // Not `b1`, which is what both the old code and an alphabetical
      // list would have given.
      expect(repo.about, ['b2']);
      expect(find.text('CIMB Savings'), findsOneWidget);
    });

    testWidgets('and on the first one when nothing was asked for',
        (tester) async {
      final repo = _FakeRepo(status());
      await show(tester, status(), repo: repo, banks: twoBanks);

      expect(repo.about, ['b1']);
    });

    testWidgets('a stale id opens the first account, not an empty screen',
        (tester) async {
      // A bookmarked link, or an account closed since. Falling through
      // to nothing would leave the figures blank with no way to say
      // why.
      final repo = _FakeRepo(status());
      await show(
        tester,
        status(),
        repo: repo,
        banks: twoBanks,
        openAccountId: 'b-gone',
      );

      expect(repo.about, ['b1']);
    });

    testWidgets('import=1 opens the import straight away', (tester) async {
      await show(
        tester,
        status(),
        banks: twoBanks,
        openAccountId: 'b2',
        openImport: true,
      );

      expect(find.text('Import statement'), findsOneWidget);
    });

    testWidgets('and only once', (tester) async {
      // The seeding block is inside `build`, which runs again on every
      // rebuild -- and `_refresh` calls `setState` twice, so it runs
      // several times before this settles. What makes it once is the
      // `_bankAccountId == null` the block is guarded by. Widen that
      // guard and the dialog reopens behind itself; closing one
      // reveals the next.
      await show(
        tester,
        status(),
        banks: twoBanks,
        openAccountId: 'b2',
        openImport: true,
      );
      await tester.pumpAndSettle();

      expect(find.text('Import statement'), findsOneWidget);

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(find.text('Import statement'), findsNothing);
    });

    testWidgets('without it the screen is just the screen', (tester) async {
      await show(tester, status(), banks: twoBanks, openAccountId: 'b2');

      expect(find.text('Import statement'), findsNothing);
    });
  });
}

/// Only what the screen asks for. Anything else throws, so a screen that
/// grows a third call fails loudly here rather than rendering a
/// reconciliation built out of empty maps.
/// `0716`: an empty ledger is not a difference.
///
/// Reported with a screenshot. A Maybank statement for October 2025 was
/// scanned and imported perfectly into an account whose ledger begins
/// in January 2026, and the screen said "24 statement lines are still
/// unmatched. A difference is a line nobody has matched, a payment
/// entered twice, or a charge the books have not heard of." All three
/// are discrepancies between two sets of records. There was one set.
void _theEmptyLedger() {
  group('why it is out', () {
    test('three named causes, where there are two sets of records', () {
      final said = whyItIsOut({'unmatched_lines': 3, 'posted_entries': 12});

      expect(said, contains('3 statement lines are still unmatched'));
      expect(said, contains('a line nobody has matched'));
    });

    test('but not where the books hold nothing by the statement date', () {
      final said = whyItIsOut({
        'unmatched_lines': 24,
        'posted_entries': 0,
        'books_start': '2026-01-02',
      });

      // The date is the useful half: it says which side of the ledger
      // the statement fell on.
      expect(said, contains('02/01/2026'));
      expect(said, contains('nothing for the statement to agree with'));
      expect(said, contains('24 statement lines have'));
      // And it must not send somebody hunting a discrepancy.
      expect(said, isNot(contains('a line nobody has matched')));
      expect(said, isNot(contains('entered twice')));
    });

    test('and one posting is enough to make it a difference again', () {
      // The boundary. `posted > 0` written as `posted > 1` reads an
      // account holding a single entry as an empty one, and every
      // fixture above uses a comfortable number.
      final said = whyItIsOut({'unmatched_lines': 3, 'posted_entries': 1});

      expect(said, contains('a line nobody has matched'));
      expect(said, isNot(contains('nothing for the statement to agree')));
    });

    test('an account with nothing ever posted to it names no date', () {
      final said = whyItIsOut({'unmatched_lines': 2, 'posted_entries': 0});

      expect(said, contains('Nothing has ever been posted'));
      expect(said, isNot(contains('books start on')));
    });

    test('a server that does not send the count keeps the old sentence', () {
      // An app talking to a deployment older than `0716`. A guess here
      // would be a confident wrong answer.
      final said = whyItIsOut({'unmatched_lines': 2});

      expect(said, contains('a line nobody has matched'));
    });

    test('one line reads as one line', () {
      expect(whyItIsOut({'unmatched_lines': 1, 'posted_entries': 4}),
          contains('1 statement line is still unmatched'));
      expect(whyItIsOut({'unmatched_lines': 1, 'posted_entries': 0}),
          contains('the statement line has'));
    });
  });

  group('which way round a posting goes', () {
    test('money in credits the account chosen', () {
      expect(postingSideNote(900), contains('credited'));
      expect(postingSideNote(900), contains('Money in'));
    });

    test('and money out debits it', () {
      // The sign is the whole rule. `0712` made a credit card obey it
      // by storing the card negated, so there is no type branch here.
      expect(postingSideNote(-400), contains('debited'));
      expect(postingSideNote(-400), contains('Money out'));
    });
  });
}

class _FakeRepo implements Repo {
  _FakeRepo(this.status);

  final Map<String, dynamic> status;

  /// Which account the screen actually reconciled, in order.
  ///
  /// The only honest way to ask which one it settled on: the dropdown
  /// shows a name, but the figures — and, for an import, the rows —
  /// go to an id.
  final List<String> about = [];

  @override
  Future<Map<String, dynamic>> bankReconciliationStatus({
    required String bankAccountId,
    required DateTime asAt,
    required double statementBalance,
  }) async {
    about.add(bankAccountId);
    return status;
  }

  /// Lines the screen will list. Empty unless a test supplies them.
  List<Map<String, dynamic>> lines = const [];

  @override
  Future<List<Map<String, dynamic>>> bankStatementLines(
    String bankAccountId, {
    bool onlyOpen = false,
  }) async =>
      lines;

  /// What the last posting was handed. Null until something posts,
  /// which is the assertion in the case where nothing should.
  Map<String, Object?>? posted;

  @override
  Future<String> postBankTransaction({
    required String transactionId,
    required String accountId,
    String? description,
    String? contactId,
  }) async {
    posted = {
      'transactionId': transactionId,
      'accountId': accountId,
      'description': description,
    };
    return 'entry-1';
  }

  @override
  Future<List<Map<String, dynamic>>> suggestBankMatches(
    String transactionId,
  ) async =>
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
