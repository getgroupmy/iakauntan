import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/core/providers.dart';
import 'package:iakauntan/src/core/theme.dart';
import 'package:iakauntan/src/data/models.dart';
import 'package:iakauntan/src/features/hr/claims_screen.dart';

/// The "For me" filter on the Claims screen.
///
/// A chain of four approvals makes "every submitted claim in the
/// company" the wrong thing to greet an approver with, so this is the
/// segment the screen opens on. Which claims it contains is the
/// database's answer, not this screen's — asserted in
/// `supabase/tests/claim_approval_chain.sql`. What is asserted here is
/// that the screen asks the right question and says the right thing when
/// the answer is empty, because an empty "For me" is good news and an
/// empty "Awaiting" is not the same thing at all.
void main() {
  /// The tile shows the claim's title, so the fixtures are told apart
  /// by that rather than by a claim number the list never renders on its
  /// own.
  ExpenseClaim claim(String title) => ExpenseClaim.fromJson({
    'id': title,
    'org_id': 'o',
    'claim_no': 'CLM-0001',
    'employee_id': 'e',
    'claim_date': '2026-03-15',
    'title': title,
    'status': 'submitted',
    'total_amount': 500,
  });

  Widget harness({
    required List<ExpenseClaim> mine,
    required List<ExpenseClaim> all,
  }) => ProviderScope(
    overrides: [
      claimsAwaitingMeProvider.overrideWith((_) async => mine),
      claimsProvider.overrideWith((_, __) async => all),
      canPostProvider.overrideWithValue(false),
    ],
    child: MaterialApp(theme: AppTheme.light(), home: const ClaimsScreen()),
  );

  testWidgets('the screen opens on the claims waiting on you', (tester) async {
    await tester.pumpWidget(
      harness(
        mine: [claim('Waiting on me')],
        all: [claim('Somebody else to clear')],
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Waiting on me'), findsOneWidget);
    expect(
      find.text('Somebody else to clear'),
      findsNothing,
      reason: 'the company-wide list is a different segment',
    );
  });

  testWidgets('and switches to every submitted claim on request', (
    tester,
  ) async {
    await tester.pumpWidget(
      harness(
        mine: [claim('Waiting on me')],
        all: [claim('Somebody else to clear')],
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Awaiting'));
    await tester.pumpAndSettle();

    expect(find.text('Somebody else to clear'), findsOneWidget);
    expect(find.text('Waiting on me'), findsNothing);
  });

  testWidgets('an empty queue reads as finished, not as nothing to see', (
    tester,
  ) async {
    await tester.pumpWidget(
      harness(mine: const [], all: [claim('Somebody else to clear')]),
    );
    await tester.pumpAndSettle();

    expect(find.text('Nothing waiting on you'), findsOneWidget);

    // The company-wide list saying "no claims here" while claims plainly
    // exist would be a different and much more alarming statement.
    await tester.tap(find.text('Awaiting'));
    await tester.pumpAndSettle();
    expect(find.text('Nothing waiting on you'), findsNothing);
  });

  testWidgets('an empty company list still says what it means', (tester) async {
    await tester.pumpWidget(harness(mine: const [], all: const []));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Awaiting'));
    await tester.pumpAndSettle();

    expect(find.text('No claims here'), findsOneWidget);
  });
}
