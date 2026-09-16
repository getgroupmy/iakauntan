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
}
