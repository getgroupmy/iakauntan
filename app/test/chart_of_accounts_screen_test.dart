import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/core/providers.dart';
import 'package:iakauntan/src/core/theme.dart';
import 'package:iakauntan/src/data/models.dart';
import 'package:iakauntan/src/features/settings/chart_of_accounts_card.dart';

/// The chart of accounts, and the door it did not have.
///
/// Reported: there should be an entry for it under General Ledger.
/// There was not — the chart lived on a card most of the way down
/// Settings, which is where a company's SETUP lives. A chart of
/// accounts is not setup. It is the thing somebody opens to look an
/// account code up, and it belongs beside the journals that post into
/// it.
///
/// What is asserted here is that there is ONE chart behind both doors.
/// A screen that drew its own copy of the list would be a second chart,
/// and the one nobody is looking at is the one that goes stale.
void main() {
  Account account({
    required String code,
    required String name,
    required String type,
    String subtype = 'current_asset',
  }) => Account(
    id: 'a-$code',
    code: code,
    name: name,
    accountType: type,
    accountSubtype: subtype,
  );

  final chart = [
    account(code: '1000', name: 'Cash at bank', type: 'asset'),
    account(
      code: '2000',
      name: 'Trade payables',
      type: 'liability',
      subtype: 'current_liability',
    ),
    account(code: '3000', name: 'Share capital', type: 'equity',
        subtype: 'equity'),
    account(code: '4000', name: 'Sales', type: 'revenue', subtype: 'revenue'),
    // All five types present, deliberately. With no expense account in
    // the fixture, dropping 'expense' from the order the chart is drawn
    // in changed nothing and the mutant survived.
    account(code: '5000', name: 'Rent', type: 'expense', subtype: 'expense'),
  ];

  Widget wrap(Widget child, {bool canPost = true}) => ProviderScope(
    overrides: [
      accountsProvider.overrideWith((ref) async => chart),
      canPostProvider.overrideWithValue(canPost),
      repoProvider.overrideWithValue(null),
    ],
    child: MaterialApp(theme: AppTheme.light(), home: child),
  );

  Future<void> show(
    WidgetTester tester,
    Widget child, {
    bool canPost = true,
    double width = 1400,
  }) async {
    tester.view.devicePixelRatio = 1.0;
    // A browser viewport, not a screen size. See signin_landscape_test:
    // picking the latter took a panel off every desktop.
    tester.view.physicalSize = Size(width, 760);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(wrap(child, canPost: canPost));
    await tester.pumpAndSettle();
  }

  group('the screen', () {
    testWidgets('names itself and draws the whole chart', (tester) async {
      await show(tester, const ChartOfAccountsScreen());

      expect(find.widgetWithText(AppBar, 'Chart of accounts'), findsOneWidget);
      // OPEN, and that is the difference from the card. A screen whose
      // entire purpose is the chart must not open on five closed
      // headings.
      expect(find.textContaining('Cash at bank'), findsOneWidget);
      expect(find.textContaining('Trade payables'), findsOneWidget);
      expect(find.textContaining('Sales'), findsOneWidget);
    });

    testWidgets('offers the three doors to somebody who may post',
        (tester) async {
      await show(tester, const ChartOfAccountsScreen());

      expect(find.text('Export'), findsOneWidget);
      expect(find.text('Import'), findsOneWidget);
      expect(find.text('Add'), findsOneWidget);
    });

    testWidgets('and withholds the two that write', (tester) async {
      // Export is not one of them: it is the same list already on the
      // screen, and refusing to let somebody save what they are looking
      // at is not a control.
      await show(tester, const ChartOfAccountsScreen(), canPost: false);

      expect(find.text('Export'), findsOneWidget);
      expect(find.text('Import'), findsNothing);
      expect(find.text('Add'), findsNothing);
      // The chart is still readable, which is the whole point of
      // withholding the buttons rather than the screen.
      expect(find.textContaining('Cash at bank'), findsOneWidget);
    });
  });

  group('its toolbar on a phone', () {
    // Flutter CLIPS an overflowing toolbar in a release build rather
    // than reporting it, so three labelled buttons on a 360-pixel bar
    // would lose the right-hand one silently. `RowActions` folds them
    // into a menu instead.
    for (final width in [360.0, 412.0, 600.0]) {
      testWidgets('fits at ${width.toInt()} and keeps every action',
          (tester) async {
        await show(tester, const ChartOfAccountsScreen(), width: width);

        // Rendering is the overflow assertion: a RenderFlex overflow is
        // a test failure. What this adds is that nothing was dropped to
        // achieve it.
        await tester.tap(find.byKey(const ValueKey('chart-actions')));
        await tester.pumpAndSettle();

        expect(find.text('Export'), findsOneWidget);
        expect(find.text('Import'), findsOneWidget);
        expect(find.text('Add'), findsOneWidget);
      });
    }

    testWidgets('and on a laptop they are buttons rather than a menu',
        (tester) async {
      // Both sides, because "they are all in the menu" alone passes
      // against a build that folds them at every width.
      await show(tester, const ChartOfAccountsScreen());

      expect(find.byKey(const ValueKey('chart-actions')), findsNothing);
      expect(find.text('Export'), findsOneWidget);
    });
  });

  group('the settings card', () {
    testWidgets('groups the same chart, and starts closed', (tester) async {
      // One implementation, two doors. The card stays collapsed: it is
      // one card among a dozen on a settings page, and a hundred
      // account rows there would bury everything under it.
      await show(
        tester,
        const Scaffold(
          body: SingleChildScrollView(child: ChartOfAccountsCard()),
        ),
      );

      expect(find.text('Chart of accounts'), findsOneWidget);
      expect(find.text('Asset'), findsOneWidget);
      expect(find.text('Liability'), findsOneWidget);
      expect(find.text('Revenue'), findsOneWidget);
      expect(find.textContaining('Cash at bank'), findsNothing);
    });

    testWidgets('and opens to the same accounts', (tester) async {
      await show(
        tester,
        const Scaffold(
          body: SingleChildScrollView(child: ChartOfAccountsCard()),
        ),
      );
      await tester.tap(find.text('Asset'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Cash at bank'), findsOneWidget);
    });

    testWidgets('and carries the same actions', (tester) async {
      await show(
        tester,
        const Scaffold(body: SingleChildScrollView(child: ChartOfAccountsCard())),
      );

      expect(find.text('Export'), findsOneWidget);
      expect(find.text('Import'), findsOneWidget);
      expect(find.text('Add'), findsOneWidget);
    });
  });

  testWidgets('every kind of account has a heading, in the order a chart '
      'is read', (tester) async {
    // Assets, liabilities, equity, revenue, expense. A chart in a
    // different order is one somebody has to search rather than scan.
    await show(tester, const ChartOfAccountsScreen());

    const headings = ['Asset', 'Liability', 'Equity', 'Revenue', 'Expense'];
    final seen = <String, double>{};
    for (final h in headings) {
      // Every one of them, not "those that happen to be there": a
      // chart missing a whole kind of account is the defect this
      // assertion exists for.
      expect(find.text(h), findsOneWidget, reason: '$h has a heading');
      seen[h] = tester.getTopLeft(find.text(h)).dy;
    }

    for (var i = 1; i < headings.length; i++) {
      expect(seen[headings[i]]!, greaterThan(seen[headings[i - 1]]!),
          reason: '${headings[i]} comes after ${headings[i - 1]}');
    }
  });
}
