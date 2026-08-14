import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/core/providers.dart';
import 'package:iakauntan/src/core/theme.dart';
import 'package:iakauntan/src/data/models.dart';
import 'package:iakauntan/src/features/settings/claim_approval_card.dart';

/// The claim approval threshold, which is the only place a company can
/// say how far up the line a claim has to go.
///
/// Two things here are easy to get wrong and expensive to get wrong.
/// Zero is the shipped default and it *looks* like "off" while meaning
/// the opposite — every claim, however small, asks the manager, the
/// department head, HR and finance. And the field starts life holding
/// the saved amount, so a card that offered to save an untouched value
/// would invite people to write back what they were already reading.
void main() {
  Widget harness({double? threshold, String role = 'owner'}) => ProviderScope(
        overrides: [
          claimApprovalThresholdProvider.overrideWith((_) async => threshold),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: ClaimApprovalCard(
              org: Organization(
                id: 'o',
                name: 'Rantaian Sdn Bhd',
                slug: 'rantaian',
              ),
              canAdmin: role == 'owner',
            ),
          ),
        ),
      );

  Finder field() => find.byKey(const ValueKey('claim-threshold'));

  Future<void> reveal(WidgetTester tester) async {
    await tester.pumpWidget(harness(threshold: 200));
    await tester.pumpAndSettle();
  }

  testWidgets('the saved threshold is what the field shows', (tester) async {
    await reveal(tester);

    expect(
      tester.widget<TextField>(field()).controller!.text,
      '200.00',
      reason: 'the card opens on what the company already set',
    );
  });

  testWidgets('an untouched card does not offer to save', (tester) async {
    await reveal(tester);

    final save = find.widgetWithText(FilledButton, 'Save');
    expect(tester.widget<FilledButton>(save).onPressed, isNull);

    // Type a different amount and it lights up.
    await tester.enterText(field(), '50');
    await tester.pumpAndSettle();
    expect(tester.widget<FilledButton>(save).onPressed, isNotNull);

    // Put it back and it goes out again, so a reverted edit is not an
    // invitation to write the same number back.
    await tester.enterText(field(), '200');
    await tester.pumpAndSettle();
    expect(tester.widget<FilledButton>(save).onPressed, isNull);
  });

  testWidgets('zero is spelled out rather than left looking like off',
      (tester) async {
    await tester.pumpWidget(harness(threshold: null));
    await tester.pumpAndSettle();

    // Never set is zero, and zero is the widest possible chain.
    expect(tester.widget<TextField>(field()).controller!.text, '0.00');
    expect(find.textContaining('Every claim goes to the manager'), findsOneWidget);
  });

  testWidgets('a threshold explains both sides of itself', (tester) async {
    await reveal(tester);

    expect(find.textContaining('RM 200.00 or more'), findsOneWidget);
    expect(find.textContaining('needs only the manager'), findsOneWidget);

    // The case that made 0121 necessary is worth saying out loud, since
    // somebody setting a threshold is exactly the person who would
    // otherwise be surprised by it.
    expect(find.textContaining('no manager on file'), findsOneWidget);
  });

  testWidgets('somebody who cannot administer the company cannot edit it',
      (tester) async {
    await tester.pumpWidget(harness(threshold: 200, role: 'employee'));
    await tester.pumpAndSettle();

    expect(tester.widget<TextField>(field()).enabled, isFalse);
    expect(find.widgetWithText(FilledButton, 'Save'), findsNothing);
  });
}
