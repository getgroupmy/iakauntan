import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/core/providers.dart';
import 'package:iakauntan/src/core/theme.dart';
import 'package:iakauntan/src/features/feedback/feedback_screen.dart';
import 'package:iakauntan/src/features/feedback/screen_catalogue.dart';

/// Saying where it happened.
///
/// The field used to ask for "the address in the bar, if you have it",
/// which is a question about the product's plumbing put to somebody who
/// has just hit a fault — and on a phone there is no address bar to read.
/// It is three lists now: module, the part of it, then the screen.
///
/// What is asserted here is the behaviour that makes a dependent picker
/// safe: the lower lists do not appear until the one above is answered,
/// and they are cleared when it changes. A sub-module left over from the
/// previous module is how a picker sends back an answer nobody meant.
void main() {
  Widget harness() => ProviderScope(
    overrides: [
      repoProvider.overrideWithValue(null),
      myFeedbackProvider.overrideWith((ref) async => const []),
    ],
    child: MaterialApp(theme: AppTheme.light(), home: const FeedbackScreen()),
  );

  Future<void> openDialog(WidgetTester tester) async {
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();
    await tester.tap(find.text('New report'));
    await tester.pumpAndSettle();
  }

  Future<void> pick(WidgetTester tester, Key key, String label) async {
    await tester.tap(find.byKey(key));
    await tester.pumpAndSettle();
    // The menu is taller than the dialog for the longer lists, so the
    // item has to be brought into view before it can be tapped.
    //
    // `skipOffstage: false` because a dropdown builds every item at
    // once and leaves the ones past the fold offstage. Once the module
    // list grew past what fits, the default finder stopped seeing them
    // and this failed with "Bad state: No element" — which reads like
    // the item is missing rather than merely out of sight.
    final item = find.text(label, skipOffstage: false).last;
    await tester.ensureVisible(item);
    await tester.pumpAndSettle();
    await tester.tap(item);
    await tester.pumpAndSettle();
  }

  testWidgets('it asks for the module first, and nothing under it yet', (
    tester,
  ) async {
    await openDialog(tester);

    expect(find.byKey(const ValueKey('feedback-module')), findsOneWidget);
    expect(find.byKey(const ValueKey('feedback-area')), findsNothing);
    expect(find.byKey(const ValueKey('feedback-screen')), findsNothing);
  });

  testWidgets('choosing a module offers its parts, then its screens', (
    tester,
  ) async {
    await openDialog(tester);

    await pick(tester, const ValueKey('feedback-module'), 'People and payroll');
    expect(find.byKey(const ValueKey('feedback-area')), findsOneWidget);
    expect(find.byKey(const ValueKey('feedback-screen')), findsNothing);

    await pick(tester, const ValueKey('feedback-area'), 'Payroll');
    expect(find.byKey(const ValueKey('feedback-screen')), findsOneWidget);

    await pick(tester, const ValueKey('feedback-screen'), 'Payroll runs');
    // What the report will carry: readable, and an address we can open.
    expect(find.text('Payroll runs (/hr/payroll)'), findsOneWidget);
  });

  testWidgets('changing the module clears what was chosen under the old one', (
    tester,
  ) async {
    await openDialog(tester);

    await pick(tester, const ValueKey('feedback-module'), 'People and payroll');
    await pick(tester, const ValueKey('feedback-area'), 'Payroll');
    await pick(tester, const ValueKey('feedback-screen'), 'Payroll runs');
    expect(find.text('Payroll runs (/hr/payroll)'), findsOneWidget);

    // A different module. The payroll screen must not still be the
    // answer — that is a report pointing somewhere nobody meant.
    await pick(tester, const ValueKey('feedback-module'), 'Point of sale');
    expect(find.text('Payroll runs (/hr/payroll)'), findsNothing);
    expect(find.byKey(const ValueKey('feedback-screen')), findsNothing);
  });

  testWidgets('somewhere else is always offered, and asks for nothing more', (
    tester,
  ) async {
    await openDialog(tester);

    await pick(tester, const ValueKey('feedback-module'), kSomewhereElse);
    // No part, no screen, and the form is still finishable: a report
    // that cannot be sent because the screen is missing from a list is
    // worse than the blank box this replaced.
    expect(find.byKey(const ValueKey('feedback-area')), findsNothing);
    expect(find.byKey(const ValueKey('feedback-screen')), findsNothing);
    expect(find.widgetWithText(AlertDialog, 'Tell us'), findsOneWidget);
  });

  testWidgets('the document lists are offered by name, not as one lump', (
    tester,
  ) async {
    await openDialog(tester);

    await pick(
      tester,
      const ValueKey('feedback-module'),
      'Sales and customers',
    );
    await pick(tester, const ValueKey('feedback-area'), 'Documents');
    await pick(tester, const ValueKey('feedback-screen'), 'Credit Notes');
    expect(find.text('Credit Notes (/sales/credit_note)'), findsOneWidget);
  });
}
