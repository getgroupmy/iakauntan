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
  ExpenseClaim claim(String title, {String status = 'submitted',
      String? paidAt}) => ExpenseClaim.fromJson({
    'id': title,
    'org_id': 'o',
    'claim_no': 'CLM-0001',
    'employee_id': 'e',
    'claim_date': '2026-03-15',
    'title': title,
    'status': status,
    'total_amount': 500,
    'paid_at': paidAt,
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
  /// Every line of this list, at every width one is opened at.
  ///
  /// `4bd1d7e` fixed both ends of this row on the ARITHMETIC in
  /// `check_narrow_rows.py` rather than by rendering, because the first
  /// probe of it was written with a malformed fixture and hung. This is
  /// the confirmation that was owed.
  ///
  /// The trailing was Money, "Reject" and "Approve" -- 168 pixels of
  /// labelled button beside the amount -- and the title carries TWO
  /// status chips on a paid claim, 168 more that a `Flexible` cannot
  /// give back. A `ListTile` does not report either: it hands the
  /// trailing the width it asks for and gives the title what is left,
  /// so a phone got a title thirty pixels wide and wrapped it one
  /// letter per line.
  group('a claim line fits', () {
    for (final width in [1400.0, 1000.0, 800.0, 700.0, 600.0, 412.0, 360.0]) {
      testWidgets('at ${width.toInt()} wide', (tester) async {
        tester.view.devicePixelRatio = 1.0;
        tester.view.physicalSize = Size(width, 900);
        addTearDown(tester.view.reset);

        // The widest a row gets: awaiting a decision, so both buttons,
        // beside a paid claim carrying both chips.
        await tester.pumpWidget(
          harness(
            mine: [claim('Taxi to the land office')],
            all: [
              claim('Taxi to the land office'),
              claim(
                'Stamp duty paid at the counter',
                status: 'approved',
                paidAt: '2026-03-20T10:00:00Z',
              ),
            ],
          ),
        );
        await tester.pumpAndSettle();

        expect(find.byType(ClaimsScreen), findsOneWidget);
      });
    }
  });

  group('deciding a claim', () {
    testWidgets('is offered as buttons on a laptop', (tester) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(1400, 900);
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        harness(mine: [claim('Taxi')], all: [claim('Taxi')]),
      );
      await tester.pumpAndSettle();

      expect(find.text('Approve'), findsOneWidget);
      expect(find.text('Reject'), findsOneWidget);
      expect(find.byKey(const ValueKey('claim-actions')), findsNothing);
    });

    testWidgets('and as one menu on a phone, with both still in it',
        (tester) async {
      // Folded, not dropped. Approving is the reason somebody opened
      // this screen, and rejecting is the other half of the decision.
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(412, 900);
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        harness(mine: [claim('Taxi')], all: [claim('Taxi')]),
      );
      await tester.pumpAndSettle();

      expect(find.text('Approve'), findsNothing);

      await tester.tap(find.byKey(const ValueKey('claim-actions')));
      await tester.pumpAndSettle();

      expect(find.text('Approve'), findsOneWidget);
      expect(find.text('Reject'), findsOneWidget);
    });
  });

}
