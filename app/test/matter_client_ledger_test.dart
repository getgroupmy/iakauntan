import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/core/providers.dart';
import 'package:iakauntan/src/core/theme.dart';
import 'package:iakauntan/src/data/models.dart';
import 'package:iakauntan/src/features/legal/matter_detail_screen.dart';

/// A solicitor's client account, as a ledger.
///
/// `matter_detail_screen.dart` is 1,232 lines and had no test. Client
/// money is somebody else's money held by the firm, and the tab that
/// shows it reads like a bank statement — which is to say it carries a
/// RUNNING BALANCE, and a running balance is only right if it is
/// accumulated in the right direction.
///
/// THE ORDER IS TWO FACTS THAT HAVE TO AGREE. `Repo.clientTransactions`
/// asks for `transaction_date` then `created_at`, both
/// `ascending: true`, so the rows arrive OLDEST FIRST. The screen
/// accumulates the balance down that list and then draws it REVERSED,
/// newest at the top, the way a statement is read. Neither half says
/// anything about the other, and flipping either one leaves a ledger
/// that still has the right rows on it, in a plausible order, with
/// every balance wrong.
///
/// `check_order_direction.py` guards that an `.order()` states its
/// direction at all — the trap postgrest-dart sets by defaulting to
/// DESC — but it cannot know which direction this screen needs. So the
/// pairing is asserted here, on the figures.
void main() {
  MatterSummary summary({double clientFunds = 0}) => MatterSummary(
    matterId: 'm1',
    matterNo: 'CONV/2026/014',
    matterName: 'Sale of shophouse',
    clientName: 'Puan Aminah',
    status: 'open',
    clientFunds: clientFunds,
    unbilledTime: 0,
    unbilledDisbursements: 0,
    billed: 0,
    outstanding: 0,
  );

  /// A movement on the client account. `amount` is SIGNED: positive is
  /// money received into the client account, negative is money paid out
  /// of it, which is what `Repo.recordClientTransaction` documents.
  ClientTransaction txn({
    required String no,
    required double amount,
    required DateTime on,
    String? description,
    String? payee,
  }) => ClientTransaction(
    id: no,
    transactionNo: no,
    transactionDate: on,
    transactionType: amount >= 0 ? 'receipt' : 'payment',
    amount: amount,
    status: 'posted',
    description: description,
    payee: payee,
  );

  /// The rows as the repository hands them over: OLDEST FIRST.
  final asStored = [
    txn(
      no: 'CA-0001',
      amount: 50000,
      on: DateTime(2026, 3, 1),
      description: 'Deposit on account',
    ),
    txn(
      no: 'CA-0002',
      amount: -12000,
      on: DateTime(2026, 4, 10),
      description: 'Stamp duty',
      payee: 'Lembaga Hasil Dalam Negeri',
    ),
    txn(
      no: 'CA-0003',
      amount: -3000,
      on: DateTime(2026, 5, 2),
      description: 'Land office search',
      payee: 'Pejabat Tanah',
    ),
  ];

  Widget harness({
    List<ClientTransaction> transactions = const [],
    bool canPost = true,
  }) => ProviderScope(
    overrides: [
      repoProvider.overrideWithValue(null),
      matterSummaryProvider.overrideWith((ref) async => [summary()]),
      canPostProvider.overrideWithValue(canPost),
      clientTransactionsProvider(
        'm1',
      ).overrideWith((ref) async => transactions),
      timeEntriesProvider('m1').overrideWith((ref) async => const []),
      disbursementsProvider('m1').overrideWith((ref) async => const []),
      canWriteProvider.overrideWithValue(canPost),
    ],
    child: MaterialApp(
      theme: AppTheme.light(),
      home: const MatterDetailScreen(matterId: 'm1'),
    ),
  );

  Future<void> show(
    WidgetTester tester, {
    List<ClientTransaction> transactions = const [],
    bool canPost = true,
    double width = 1400,
  }) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = Size(width, 1000);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      harness(transactions: transactions, canPost: canPost),
    );
    await tester.pumpAndSettle();
  }

  group('the running balance', () {
    testWidgets('carries the whole account on the newest line',
        (tester) async {
      // 50,000 in, 12,000 out, 3,000 out. The top line is the newest
      // movement and the balance beside it is what the firm still holds
      // for this client: 35,000.
      //
      // Accumulated the other way round, the top line would read 3,000
      // — the oldest movement's own amount — which is a plausible
      // number on a plausible ledger and is not the client's money.
      await show(tester, transactions: asStored);

      expect(find.text('bal RM 35,000.00'), findsOneWidget);
    });

    testWidgets('and the oldest line carries only itself', (tester) async {
      // The other end of the same rule. A statement starts at its first
      // movement, so the bottom line's balance is that deposit alone.
      await show(tester, transactions: asStored);

      expect(find.text('bal RM 50,000.00'), findsOneWidget);
      // And the middle: 50,000 less the 12,000 stamp duty.
      expect(find.text('bal RM 38,000.00'), findsOneWidget);
    });

    testWidgets('newest is at the top', (tester) async {
      // A statement is read from the most recent movement down. The
      // balance arithmetic runs the other way, which is exactly why
      // both directions have to be asserted rather than either alone.
      await show(tester, transactions: asStored);

      final newest = tester.getCenter(find.text('Land office search')).dy;
      final oldest = tester.getCenter(find.text('Deposit on account')).dy;
      expect(newest, lessThan(oldest));
    });
  });

  group('money in and money out', () {
    testWidgets('are drawn differently', (tester) async {
      // Which way the money went is the first thing somebody checks on
      // a client account, and the arrow is how the row says it.
      await show(tester, transactions: asStored);

      final colours = AppTheme.light().extension<AppColors>()!;

      final inbound = tester.widget<Icon>(
        find.descendant(
          of: find.widgetWithText(ListTile, 'Deposit on account'),
          matching: find.byType(Icon),
        ),
      );
      final outbound = tester.widget<Icon>(
        find.descendant(
          of: find.widgetWithText(ListTile, 'Stamp duty'),
          matching: find.byType(Icon),
        ),
      );

      expect(inbound.icon, Icons.south_west);
      expect(inbound.color, colours.success);
      expect(outbound.icon, Icons.north_east);
      expect(outbound.color, colours.warning);
    });

    testWidgets('and a payment says who it went to', (tester) async {
      // The whole line. On a client account "who received it" is the
      // question an audit asks, and a `textContaining` on any part of
      // this passes while the payee goes missing.
      await show(tester, transactions: asStored);

      expect(
        find.text('CA-0002 · 10/04/2026 · to Lembaga Hasil Dalam Negeri'),
        findsOneWidget,
      );
      // A receipt has no payee, and says so by leaving it out rather
      // than by printing an empty separator.
      expect(find.text('CA-0001 · 01/03/2026'), findsOneWidget);
    });
  });

  group('an empty client account', () {
    testWidgets('says the money is held separately', (tester) async {
      // Not "no transactions". The separation of client money from the
      // firm's own is the rule the whole tab exists for.
      await show(tester);

      expect(find.text('No client money yet'), findsOneWidget);
      expect(
        find.textContaining('held separately from office money'),
        findsOneWidget,
      );
    });
  });

  group('who may move client money', () {
    testWidgets('somebody who may post is offered both ways', (tester) async {
      await show(tester, transactions: asStored);

      expect(find.byTooltip('Move to another matter'), findsOneWidget);
      expect(find.text('Client money'), findsOneWidget);
    });

    testWidgets('and somebody who may not is offered neither',
        (tester) async {
      // Client money is a regulated ledger. Offering the button to
      // somebody the database will refuse is an invitation to try.
      await show(tester, transactions: asStored, canPost: false);

      expect(find.byTooltip('Move to another matter'), findsNothing);
      expect(find.text('Client money'), findsNothing);
      // The ledger itself is still readable.
      expect(find.text('Deposit on account'), findsOneWidget);
    });
  });

  group('the ledger fits', () {
    for (final width in [1400.0, 1000.0, 800.0, 600.0, 412.0, 360.0]) {
      testWidgets('at ${width.toInt()} wide', (tester) async {
        await show(tester, transactions: asStored, width: width);

        expect(find.byType(MatterDetailScreen), findsOneWidget);
      });
    }
  });

  group('the rate on an hour of somebody\'s time', () {
    // `app.calc_time_entry` in `0021` values an entry as
    // `minutes / 60 * coalesce(hourly_rate, 0)`, and nothing fills the
    // rate in from the matter afterwards. So a rate that reads as
    // nought is a billable hour worth nothing -- on the matter, and on
    // the bill.
    //
    // The box was read with `double.tryParse(text) ?? 0` and had no
    // validator, so "1,200" was that nought. It is also pre-filled from
    // the matter's agreed rate, which makes editing it the ordinary
    // path rather than an unusual one.

    test('a figure is accepted, however it is written', () {
      expect(timeEntryRateProblem('1200'), isNull);
      expect(timeEntryRateProblem('1,200'), isNull);
      expect(timeEntryRateProblem('RM 1,200.00'), isNull);
      expect(timeEntryRateProblem('  850.50  '), isNull);
    });

    test('an empty box is allowed, because the rate is not required', () {
      // A matter with no agreed rate leaves it blank, and the entry is
      // recorded unvalued on purpose. Refusing this would be a
      // different bug in the other direction.
      expect(timeEntryRateProblem(''), isNull);
      expect(timeEntryRateProblem('   '), isNull);
    });

    test('text that is not a figure is refused rather than zeroed', () {
      expect(timeEntryRateProblem('twelve hundred'), isNotNull);
      expect(timeEntryRateProblem('1,20'), isNotNull);
      expect(timeEntryRateProblem('1.2.0'), isNotNull);
    });

    test('and so is a negative rate', () {
      expect(timeEntryRateProblem('-500'), contains('below zero'));
    });

    testWidgets('and the box in the dialog actually uses it', (tester) async {
      // The two mutants a unit test of the function above cannot kill:
      // dropping the `validator:` from the field, and reading the box
      // with `double.tryParse` at save time anyway. Either leaves
      // `timeEntryRateProblem` perfect and the dialog broken, which is
      // the whole defect back again.
      await show(tester);
      // The button lives on the Time tab, behind `canWrite`.
      await tester.tap(find.widgetWithText(Tab, 'Time'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(
        FloatingActionButton,
        'Record time',
      ));
      await tester.pumpAndSettle();

      final rate = find.ancestor(
        of: find.text('Rate'),
        matching: find.byType(TextFormField),
      );
      expect(rate, findsOneWidget);

      await tester.enterText(rate, 'twelve hundred');
      await tester.pump();

      expect(
        find.text('Enter an hourly rate, or leave it empty.'),
        findsOneWidget,
      );

      // And the live value line, which reads the same box, does not
      // quietly price the hour at nothing.
      await tester.enterText(
        find.ancestor(
          of: find.text('Hours *'),
          matching: find.byType(TextFormField),
        ),
        '2',
      );
      await tester.pump();
      // Scoped to the dialog: the summary card behind it is full of
      // zero figures, and an unscoped `find.text('RM 0.00')` matches
      // those instead of the line being tested.
      Finder inDialog(String text) => find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text(text),
      );
      expect(inDialog('RM 0.00'), findsNothing);

      // Corrected, with a comma, the value appears and is right.
      await tester.enterText(rate, '1,200');
      await tester.pump();
      expect(find.text('Enter an hourly rate, or leave it empty.'),
          findsNothing);
      expect(inDialog('RM 2,400.00'), findsOneWidget);
    });

    // TWO MUTANTS SURVIVE HERE, and neither is a missing assertion that
    // could be added from a widget test.
    //
    // Reading the HOURS box with `double.tryParse` instead survives
    // because the two readings differ only on text nobody puts in an
    // hours box -- "2%" or "1 5". The box uses the same function as the
    // rate for the sake of one rule rather than two, not because the
    // difference is observable.
    //
    // Parsing the rate box a SECOND time inside `_save`, loosely, also
    // survives, and that one is a real defect that cannot be caught
    // here: `Repo.addTimeEntry` is declared on `extension RepoExtras on
    // Repo`, and a Dart extension method binds to the STATIC type. A
    // `_FakeRepo implements Repo` does not intercept it -- the real
    // body runs against the fake and reaches `client`, which is not
    // something a test can stand in for. Checked, not assumed: a fake
    // with `addTimeEntry` on it never saw the call.
    //
    // What closes it instead is that `_save` and the value line on the
    // screen now read `_rateTyped`, one getter, so a mutant that
    // changes the getter is caught by the figure the dialog shows. A
    // second parse written back into `_save` would get past this file
    // and is what `docs/widget-tests.md` now warns about.

    test('the refusal says what to do about it', () {
      // Including that leaving it empty is an option -- somebody who
      // has just been refused needs to know the blank box was allowed
      // all along, or they invent a number.
      final problem = timeEntryRateProblem('twelve hundred')!;
      expect(problem.toLowerCase(), contains('empty'));
    });
  });
}
