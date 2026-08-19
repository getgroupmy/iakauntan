import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/core/providers.dart';
import 'package:iakauntan/src/core/theme.dart';
import 'package:iakauntan/src/features/pos/member_panel.dart';

/// The card, at the counter.
///
/// What the arithmetic comes to is asserted in
/// `supabase/tests/pos_loyalty.sql`, against the functions that decide
/// it. What is asserted here is the one thing a screen can get wrong on
/// its own: which number it reads out. The ledger is untouched until
/// the sale completes, so the balance a member holds now and the
/// balance they will hold after paying are two different figures, and a
/// panel that showed only the first would have the cashier promising
/// points the customer is about to spend.
void main() {
  Map<String, dynamic> member({
    String? accountId = 'acct-1',
    String? contactId = 'c-1',
    String? program = 'Kad Mesra',
    int points = 506,
    int pointsAfter = 206,
    int redeemed = 300,
    num discount = 3.00,
    int minRedeem = 100,
    int wouldEarn = 75,
  }) => {
    'contact_id': contactId,
    'contact_name': 'Puan Aminah binti Yusof',
    'account_id': accountId,
    'card_no': 'MESRA-0001',
    'program': program,
    'points': points,
    'worth': '5.06',
    'points_after': pointsAfter,
    'points_redeemed': redeemed,
    'discount': '$discount',
    'min_redeem': minRedeem,
    'value_per_point': '0.0100',
    'would_earn': wouldEarn,
  };

  Widget harness(Map<String, dynamic>? row) => ProviderScope(
    overrides: [
      posSaleMemberProvider.overrideWith((_, __) async => row),
    ],
    child: MaterialApp(
      theme: AppTheme.light(),
      home: const Scaffold(body: MemberPanel(saleId: 'sale-1')),
    ),
  );

  testWidgets('a redemption says what the balance will be, not just what it is', (
    tester,
  ) async {
    await tester.pumpWidget(harness(member()));
    await tester.pumpAndSettle();

    expect(find.text('Puan Aminah binti Yusof'), findsOneWidget);
    // Both figures, because only one of them is true in a minute.
    expect(find.textContaining('506 points'), findsOneWidget);
    expect(find.textContaining('206 left after paying'), findsOneWidget);
    expect(find.textContaining('RM 3.00 off'), findsOneWidget);

    // A redemption that is already on can be changed or taken off, and
    // is not offered a second time.
    expect(find.text('Take it off'), findsOneWidget);
    expect(find.text('Use points'), findsNothing);
  });

  testWidgets('a balance short of the minimum says how short', (tester) async {
    await tester.pumpWidget(
      harness(member(points: 6, pointsAfter: 6, redeemed: 0, discount: 0)),
    );
    await tester.pumpAndSettle();

    // Disabled with the reason on the button rather than hidden: "you
    // need 100" is the answer the customer actually wants, and a
    // missing button answers nothing.
    expect(find.text('Redeems from 100'), findsOneWidget);
    final button = tester.widget<TextButton>(
      find.widgetWithText(TextButton, 'Redeems from 100'),
    );
    expect(button.onPressed, isNull);
  });

  testWidgets('an unnamed bill offers to find the customer', (tester) async {
    await tester.pumpWidget(
      harness(
        member(
          accountId: null,
          contactId: null,
          redeemed: 0,
          discount: 0,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('No card on this bill'), findsOneWidget);
    expect(find.text('Find'), findsOneWidget);
  });

  testWidgets('a named customer who is not a member is offered a card', (
    tester,
  ) async {
    await tester.pumpWidget(
      harness(member(accountId: null, redeemed: 0, discount: 0)),
    );
    await tester.pumpAndSettle();

    expect(find.text('Sign up'), findsOneWidget);
    // The nudge worth making: joining earns on this bill, not the next.
    expect(find.textContaining('earns 75 on this bill'), findsOneWidget);
  });

  testWidgets('no programme means no panel at all', (tester) async {
    await tester.pumpWidget(harness(member(program: null)));
    await tester.pumpAndSettle();

    // Not an empty card — nothing. There is nothing to join and nothing
    // to spend, and a box saying so is a box in the way of the total.
    expect(find.byType(Card), findsNothing);
    expect(find.text('Puan Aminah binti Yusof'), findsNothing);
  });
}
