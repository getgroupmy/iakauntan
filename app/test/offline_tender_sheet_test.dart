import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/core/theme.dart';
import 'package:iakauntan/src/features/pos/offline_till.dart';

/// The till's tender box, driven.
///
/// `tenderTyped` being right is not the same as this sheet using it,
/// which has cost a surviving mutant four times this session. So the
/// sheet itself is mounted and typed into.
///
/// What it is protecting: the change. `0209` works it out as
/// `round(v_cashin - v_cashdue, 2)`, and both tills used to read the
/// box as `double.tryParse(text) ?? due`. A hundred ringgit handed over
/// for a basket of 43.50, with the letter O typed for a nought, made
/// the cash in equal the cash due — "No change", and a customer 56.50
/// short with a receipt agreeing.
void main() {
  Future<void> show(WidgetTester tester, {double total = 43.50}) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(412, 900);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: OfflinePaySheet(
            total: total,
            tenders: const [
              {'id': 't-cash', 'name': 'Cash'},
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> type(WidgetTester tester, String text) async {
    await tester.enterText(find.byType(TextField), text);
    await tester.pump();
  }

  bool takeItEnabled(WidgetTester tester) =>
      tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Take it'),
      ).onPressed !=
      null;

  testWidgets('an empty box is exact money and takes the sale',
      (tester) async {
    await show(tester);

    expect(find.text('No change'), findsOneWidget);
    expect(takeItEnabled(tester), isTrue);
  });

  testWidgets('a hundred given for 43.50 shows the change', (tester) async {
    await show(tester);
    await type(tester, '100');

    // 43.50 rounds to 43.50 at five sen, so the change is 56.50.
    expect(find.text('Change RM 56.50'), findsOneWidget);
    expect(takeItEnabled(tester), isTrue);
  });

  testWidgets('a box that cannot be read says so and refuses the sale',
      (tester) async {
    // The defect, at the counter. This used to read "No change" — the
    // same words an exact payment produces — and the button was live.
    await show(tester);
    await type(tester, '1OO');

    expect(find.text('That is not an amount'), findsOneWidget);
    expect(find.text('No change'), findsNothing);
    expect(takeItEnabled(tester), isFalse);
  });

  testWidgets('and correcting it brings the sale back', (tester) async {
    // Both directions: a sheet that refused everything would pass the
    // test above and take no money at all.
    await show(tester);
    await type(tester, '1OO');
    expect(takeItEnabled(tester), isFalse);

    await type(tester, '100');

    expect(find.text('Change RM 56.50'), findsOneWidget);
    expect(takeItEnabled(tester), isTrue);
  });

  testWidgets('money written the way a till is typed into is read',
      (tester) async {
    await show(tester);
    await type(tester, 'RM 100');

    expect(find.text('Change RM 56.50'), findsOneWidget);
    expect(takeItEnabled(tester), isTrue);
  });

  testWidgets('less than the basket is still refused', (tester) async {
    // The guard that was already there, kept: a till does not take a
    // sale for less than it is owed.
    await show(tester);
    await type(tester, '20');

    expect(takeItEnabled(tester), isFalse);
  });
}
