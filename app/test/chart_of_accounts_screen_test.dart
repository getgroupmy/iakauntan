import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show SupabaseClient;

import 'package:iakauntan/src/core/providers.dart';
import 'package:iakauntan/src/core/theme.dart';
import 'package:iakauntan/src/data/models.dart';
import 'package:iakauntan/src/data/repository.dart';
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

  group('saving an edit sends what the account already is (0766)', () {
    // Built once, outside any test: a client made inside one starts
    // timers the framework then reports as left running.
    setUpAll(() => _unusedClient);

    // The dialog called `upsertAccount` with neither `isGroup` nor
    // `parentId`, so every save went to the database as `is_group:
    // false` with no parent. Renaming a heading made it a postable
    // leaf with its children still under it, and renaming anything
    // took it out from under its parent -- two production companies
    // lost a seeded heading that way. The database refuses the first
    // now; the second is only ever what the app sends, so it is
    // asserted here, on the parameters the RPC receives.
    //
    // Neither half collapses into the fallback: the heading's `true`
    // is not the old `false`, and the leaf's parent is not the old
    // null. Each case also catches the other's wrong answer -- a
    // dialog that always said "heading" fails the leaf, and one that
    // sent the account's own id as its parent fails the heading.
    final heading = Account(
      id: 'a-6000',
      code: '6000',
      name: 'EXPENSES',
      accountType: 'expense',
      accountSubtype: 'operating_expense',
      isGroup: true,
    );
    final leaf = Account(
      id: 'a-6200',
      code: '6200',
      name: 'Rental',
      accountType: 'expense',
      accountSubtype: 'operating_expense',
      parentId: 'a-6000',
    );

    Future<Map<String, dynamic>> saveRenamed(
      WidgetTester tester,
      String row,
      String from,
      String to,
    ) async {
      final repo = _RecordingRepo();
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(1400, 760);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(ProviderScope(
        overrides: [
          accountsProvider.overrideWith((ref) async => [heading, leaf]),
          canPostProvider.overrideWithValue(true),
          repoProvider.overrideWithValue(repo),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const ChartOfAccountsScreen(),
        ),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.text(row));
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextField, from), to);
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      final upserts =
          repo.calls.where((c) => c.$1 == 'upsert_account').toList();
      expect(upserts, hasLength(1), reason: 'one save, one call');
      return upserts.single.$2!;
    }

    testWidgets('a heading renamed stays a heading', (tester) async {
      final p = await saveRenamed(
          tester, '6000  EXPENSES', 'EXPENSES', 'Operating Expenses');

      expect(p['p_id'], 'a-6000');
      expect(p['p_name'], 'Operating Expenses');
      expect(p['p_is_group'], isTrue);
      expect(p['p_parent_id'], isNull);
    });

    testWidgets('and an account renamed stays under its heading',
        (tester) async {
      final p = await saveRenamed(tester, '6200  Rental', 'Rental', 'Sewa');

      expect(p['p_id'], 'a-6200');
      expect(p['p_name'], 'Sewa');
      expect(p['p_is_group'], isFalse);
      expect(p['p_parent_id'], 'a-6000');
    });
  });
}

/// The real repository, so `upsertAccount`'s own mapping to `p_*` is
/// what gets asserted, with the network taken out underneath it.
class _RecordingRepo extends Repo {
  _RecordingRepo() : super(_unusedClient, 'org-1');

  final List<(String, Map<String, dynamic>?)> calls = [];

  @override
  Future<dynamic> callRpc(String fn, {Map<String, dynamic>? params}) async {
    calls.add((fn, params));
    if (fn != 'upsert_account') return null;
    return params?['p_id'] ?? 'a-new';
  }

  @override
  Future<void> setAccountTaxTreatment(String id, String? treatment) async {}
}

final _unusedClient = SupabaseClient('https://example.invalid', 'not-a-key');
