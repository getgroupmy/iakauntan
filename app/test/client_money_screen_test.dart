import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iakauntan/src/core/providers.dart';
import 'package:iakauntan/src/data/models.dart';
import 'package:iakauntan/src/features/legal/client_money_screen.dart';

/// Client money, as the screen puts it in front of a solicitor.
///
/// `app.assert_client_funds` is the real defence and is asserted in
/// `client_account.sql`; `client_money_copy_test.dart` proves the words
/// of the overdraw warning. Neither says the SCREEN asks the right
/// question, and two of its decisions are ones a firm is regulated on:
///
///   * money held on account is NOT the firm's income, and the page has
///     to say so. A client account misstated as revenue is the thing
///     the rules exist about.
///   * the overdraw warning reads the balance OF THE MATTER BEING PAID
///     FROM. Reading anything else -- a total across matters, a stale
///     selection -- suppresses it exactly when one client's money would
///     fund another's payment, which is the breach itself.
///
/// The second is a one-character mistake (`[_matterId]` versus a sum)
/// that no test below the widget can see, and it fails in the quiet
/// direction: the dialog simply stops warning.
void main() {
  Matter matter(String id, String no, String name) => Matter(
    id: id,
    matterNo: no,
    name: name,
    clientId: 'c-$id',
    status: 'open',
    clientName: 'Client $id',
  );

  Map<String, dynamic> txn({
    required String id,
    required String type,
    required num amount,
    String matterNo = 'M-1',
    String client = 'Puan Aminah',
    String? payee,
    String date = '2026-01-20',
    String? description,
  }) => {
    'id': id,
    'transaction_type': type,
    'amount': amount,
    'transaction_date': date,
    'description': description,
    'payee': payee,
    'matters': {
      'matter_no': matterNo,
      'contacts': {'name': client},
    },
  };

  Widget wrap({
    required bool inbound,
    List<Map<String, dynamic>> receipts = const [],
    List<Map<String, dynamic>> payouts = const [],
    Map<String, double> held = const {},
    List<Matter> matters = const [],
    bool canPost = true,
  }) => ProviderScope(
    overrides: [
      clientReceiptsProvider.overrideWith((ref) async => receipts),
      clientPayoutsProvider.overrideWith((ref) async => payouts),
      matterClientBalancesProvider.overrideWith((ref) async => held),
      mattersProvider((status: 'open', search: '')).overrideWith(
        (ref) async => matters,
      ),
      canPostProvider.overrideWithValue(canPost),
    ],
    child: MaterialApp(home: ClientMoneyScreen(inbound: inbound)),
  );

  group('which half of the ledger is on the page', () {
    testWidgets('money in says it is held, and is not income', (tester) async {
      await tester.pumpWidget(
        wrap(
          inbound: true,
          receipts: [txn(id: 'r1', type: 'receipt', amount: 5000)],
          payouts: [txn(id: 'p1', type: 'payment', amount: -300)],
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Money received on account'), findsOneWidget);
      // The statutory point, in the subtitle, where a bookkeeper reads it.
      expect(find.textContaining('Not income'), findsOneWidget);
      // And the receipts, not the payments.
      expect(find.byKey(const ValueKey('client-txn-r1')), findsOneWidget);
      expect(find.byKey(const ValueKey('client-txn-p1')), findsNothing);
    });

    testWidgets('and money out shows the other list entirely', (tester) async {
      await tester.pumpWidget(
        wrap(
          inbound: false,
          receipts: [txn(id: 'r1', type: 'receipt', amount: 5000)],
          payouts: [txn(id: 'p1', type: 'payment', amount: -300)],
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Paid out for clients'), findsOneWidget);
      expect(find.byKey(const ValueKey('client-txn-p1')), findsOneWidget);
      expect(find.byKey(const ValueKey('client-txn-r1')), findsNothing);
    });

    testWidgets('a payment out is shown as a positive amount', (tester) async {
      await tester.pumpWidget(
        wrap(
          inbound: false,
          payouts: [
            txn(id: 'p1', type: 'payment', amount: -300, payee: 'Land Office'),
          ],
        ),
      );
      await tester.pumpAndSettle();

      // Stored as a negative movement and read by a person as an
      // amount. "RM -300.00" in a column of payments is a figure
      // somebody subtracts twice.
      expect(find.text('RM 300.00'), findsOneWidget);
      expect(find.textContaining('to Land Office'), findsOneWidget);
    });
  });

  group('what the firm is holding altogether', () {
    testWidgets('is the sum, and counts the matters it is spread over', (
      tester,
    ) async {
      await tester.pumpWidget(
        wrap(
          inbound: true,
          held: const {'m-1': 5000, 'm-2': 1500.50},
        ),
      );
      await tester.pumpAndSettle();

      // The number a partner is asked for and the one the client
      // account reconciliation starts from.
      expect(
        find.textContaining('RM 6,500.50 held in the client account'),
        findsOneWidget,
      );
      expect(find.text('across 2 matters'), findsOneWidget);
    });

    testWidgets('and a matter holding nothing is not one of them', (
      tester,
    ) async {
      await tester.pumpWidget(
        wrap(
          inbound: true,
          held: const {'m-1': 5000, 'm-2': 0},
        ),
      );
      await tester.pumpAndSettle();

      // A matter that has been paid out in full is not a matter the
      // firm holds money for, and saying "across 2 matters" over one
      // balance invites somebody to go looking for the second.
      expect(find.text('for one matter'), findsOneWidget);
    });
  });

  group('the overdraw warning', () {
    Future<void> openDialog(
      WidgetTester tester, {
      required bool inbound,
      required Map<String, double> held,
      required List<Matter> matters,
    }) async {
      await tester.pumpWidget(
        wrap(inbound: inbound, held: held, matters: matters),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byType(FloatingActionButton));
      await tester.pumpAndSettle();
    }

    testWidgets('reads the balance of the matter being paid FROM', (
      tester,
    ) async {
      await openDialog(
        tester,
        inbound: false,
        // M-2 is flush and M-1 is nearly empty. A warning computed off
        // a total, or off the wrong matter, stays silent on the payment
        // that would spend M-2's money on M-1's bill.
        held: const {'m-1': 100, 'm-2': 9000},
        matters: [matter('m-1', 'M-1', 'Sale of land'),
                  matter('m-2', 'M-2', 'Probate')],
      );

      await tester.tap(find.byKey(const ValueKey('client-money-matter')));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('M-1 · Sale of land').last);
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const ValueKey('client-money-amount')), '500');
      await tester.pumpAndSettle();

      expect(find.textContaining('This matter holds RM 100.00'), findsOneWidget);
      expect(
        find.textContaining('cannot fund another'),
        findsOneWidget,
      );
    });

    testWidgets('and stays quiet within what the matter holds', (tester) async {
      await openDialog(
        tester,
        inbound: false,
        held: const {'m-1': 100, 'm-2': 9000},
        matters: [matter('m-1', 'M-1', 'Sale of land'),
                  matter('m-2', 'M-2', 'Probate')],
      );

      await tester.tap(find.byKey(const ValueKey('client-money-matter')));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('M-2 · Probate').last);
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const ValueKey('client-money-amount')), '500');
      await tester.pumpAndSettle();

      // The control. Without it a dialog that warned always would pass
      // the assertion above.
      expect(find.textContaining('This matter holds'), findsNothing);
    });

    testWidgets('money coming in has no ceiling', (tester) async {
      await openDialog(
        tester,
        inbound: true,
        held: const {'m-1': 100},
        matters: [matter('m-1', 'M-1', 'Sale of land')],
      );

      await tester.tap(find.byKey(const ValueKey('client-money-matter')));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('M-1 · Sale of land').last);
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const ValueKey('client-money-amount')), '50000');
      await tester.pumpAndSettle();

      // A client may place more with the firm whenever they like.
      expect(find.textContaining('This matter holds'), findsNothing);
    });
  });

  testWidgets('somebody who may not post is offered nothing to press', (
    tester,
  ) async {
    await tester.pumpWidget(wrap(inbound: false, canPost: false));
    await tester.pumpAndSettle();

    // Reading the client ledger and moving client money are different
    // permissions, and the second is the one the rules are about.
    expect(find.byType(FloatingActionButton), findsNothing);
  });
}
