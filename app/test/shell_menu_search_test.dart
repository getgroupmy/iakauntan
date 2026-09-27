import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:iakauntan/src/core/providers.dart';
import 'package:iakauntan/src/core/theme.dart';
import 'package:iakauntan/src/data/models.dart';
import 'package:iakauntan/src/data/platform_catalog_repository.dart';
import 'package:iakauntan/src/features/shell/app_shell.dart';

/// A box at the top of the menu that narrows it as you type.
///
/// With every module switched on the side menu has twenty-one doors and
/// is taller than a laptop screen — `shell_rail_scroll_test.dart` is
/// about being able to REACH the twenty-first, and this is about not
/// having to scroll past fifteen to get to it.
///
/// Two things here are not obvious and both would ship broken:
///
///   * `NavigationRail` asserts its `selectedIndex` is inside
///     `destinations`. Most searches throw the page you are on out of
///     the list, so a filtered rail with the index left alone throws
///     while building — and a release build renders a thrown build as
///     a blank page with no clue why.
///   * The grouped menu used to be keyed on a destination's INDEX in
///     the unfiltered list. Filtering reorders and shortens that list,
///     so every row would have navigated somewhere else.
void main() {
  /// What the platform calls each module, and which heading it sits
  /// under.
  ///
  /// Overridden rather than left to fall back, and that is not
  /// decoration: with this unset `groupNames` is empty, the headings
  /// become the module CODES, and the keyword that lets somebody type
  /// "people" to find Payroll becomes the string "hr" — so a test
  /// without it passes whether or not the heading is searched at all.
  /// A mutation run said exactly that.
  const labels = <String, ({String name, String group})>{
    'hr': (name: 'HR', group: 'People'),
    'payroll': (name: 'Payroll', group: 'People'),
    'sales': (name: 'Sales', group: 'Money in'),
    'purchases': (name: 'Purchases', group: 'Money out'),
    'accounting': (name: 'Accounting', group: 'Books'),
    'contacts': (name: 'Contacts', group: 'Books'),
  };

  Widget harness(Set<String> modules, {String location = '/dashboard'}) =>
      ProviderScope(
        overrides: [
          currentUserProvider.overrideWithValue(null),
          authStateProvider
              .overrideWith((_) => const Stream<AuthState>.empty()),
          isPlatformAdminProvider.overrideWith((_) async => false),
          organizationsProvider.overrideWith((_) async => [
                Organization(
                  id: 'o1',
                  name: 'Sinar Teknologi Sdn Bhd',
                  slug: 'sinar',
                  baseCurrency: 'MYR',
                ),
              ]),
          currentOrgProvider.overrideWith((_) async => null),
          enabledModulesProvider.overrideWith((_) async => modules),
          moduleLabelsProvider.overrideWith((_) async => labels),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: AppShell(
            location: location,
            child: const Scaffold(body: Text('body')),
          ),
        ),
      );

  /// Every module, including the core three. Since 0234 tagged the
  /// destinations that used to carry no module at all, a set without
  /// `sales`, `accounting` and `contacts` is a SHORT menu — which is
  /// the opposite of what a search box is for.
  const everything = {
    'sales', 'accounting', 'contacts',
    'purchases', 'legal', 'inventory', 'crm', 'einvoice',
    'hr', 'payroll', 'secretarial', 'fixed_assets',
    'pos', 'ticketing', 'timesheets', 'property_strata',
    'approvals', 'mbrs', 'forecasting', 'chat', 'manufacturing',
  };

  /// Wide enough for the EXTENDED rail, which is the only place the box
  /// appears: collapsed, the menu is eighty pixels of icons with
  /// nowhere to put one. Tall, so nothing is off screen for reasons
  /// that have nothing to do with the filter.
  Future<void> pumpRail(
    WidgetTester tester,
    Set<String> modules, {
    String location = '/dashboard',
  }) async {
    tester.view.physicalSize = const Size(1400, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(harness(modules, location: location));
    await tester.pumpAndSettle();
  }

  Future<void> type(WidgetTester tester, String query) async {
    await tester.enterText(find.byKey(const ValueKey('menu-search')), query);
    await tester.pumpAndSettle();
  }

  group('the side menu', () {
    testWidgets('carries a search box once it is long enough to scroll',
        (tester) async {
      await pumpRail(tester, everything);
      expect(find.byKey(const ValueKey('menu-search')), findsOneWidget);
      expect(find.text('Search the menu'), findsOneWidget);
    });

    testWidgets('and none while the whole menu already fits', (tester) async {
      // A box to search a list you can see all of is one more thing to
      // read before you find what you came for.
      await pumpRail(tester, const {});
      expect(find.byKey(const ValueKey('menu-search')), findsNothing);
      // Still a menu, though — this is not the no-company layout.
      expect(find.text('Settings'), findsOneWidget);
    });

    testWidgets('and none on the collapsed rail, which has no room',
        (tester) async {
      // Between the two breakpoints the menu is eighty pixels of icons.
      // There is nowhere to put a box, and nothing to fix: a column of
      // icons is a quarter the height of the same column with words
      // beside it and was never the thing anybody had to scroll.
      tester.view.physicalSize = const Size(1000, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(harness(everything));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey('menu-search')), findsNothing);
      // Still the rail, not the bottom bar.
      expect(find.byType(NavigationRail), findsOneWidget);
    });

    testWidgets('narrows to what was typed and drops the rest',
        (tester) async {
      await pumpRail(tester, everything);
      expect(find.text('All Contacts'), findsOneWidget);
      expect(find.text('Settings'), findsOneWidget);

      await type(tester, 'contact');

      expect(tester.takeException(), isNull);
      expect(find.text('All Contacts'), findsOneWidget);
      expect(find.text('Settings'), findsNothing);
      expect(find.text('Dashboard'), findsNothing);
    });

    testWidgets('does not throw when the page you are on is filtered out',
        (tester) async {
      // The assertion inside `NavigationRail`. `/dashboard` is where
      // this harness starts, and "payroll" does not match it — so the
      // selected index points past the end of a two-item list unless
      // it is passed as null.
      await pumpRail(tester, everything, location: '/dashboard');
      await type(tester, 'payroll');

      expect(tester.takeException(), isNull);
      expect(find.text('Dashboard'), findsNothing);
      expect(find.text('Payroll'), findsWidgets);
    });

    testWidgets('and not when nothing matches at all', (tester) async {
      // Zero destinations is the other end of the same assertion, and
      // an empty menu with no explanation reads as the app having
      // broken rather than as a search that found nothing.
      await pumpRail(tester, everything);
      await type(tester, 'xyzzy');

      expect(tester.takeException(), isNull);
      expect(find.text('Nothing in the menu matches that.'), findsOneWidget);
      expect(find.text('Settings'), findsNothing);
    });

    testWidgets('matches words in any order, as every picker does',
        (tester) async {
      // The menu's matcher is the searchable picker's matcher, so what
      // is already in everybody's fingers works here: every word has to
      // match something, in any order.
      await pumpRail(tester, everything);
      await type(tester, 'setup hr');

      expect(tester.takeException(), isNull);
      expect(find.text('HR setup'), findsOneWidget);
    });

    testWidgets('a heading brings up everything under it', (tester) async {
      // "People" is the heading over HR and Payroll and is not in any
      // of their labels, so this can only pass if the group name is
      // one of the things being searched.
      await pumpRail(tester, everything);
      await type(tester, 'people');

      expect(tester.takeException(), isNull);
      expect(find.text('Payroll'), findsOneWidget);
      expect(find.text('HR setup'), findsOneWidget);
      expect(find.text('Settings'), findsNothing);
      expect(find.text('Sales'), findsNothing);
    });

    testWidgets('finds a door by the route as well as the name',
        (tester) async {
      await pumpRail(tester, everything);
      await type(tester, '/purchases');

      expect(tester.takeException(), isNull);
      expect(find.text('Purchases'), findsOneWidget);
      expect(find.text('Dashboard'), findsNothing);
    });

    testWidgets('the clear button puts the whole menu back', (tester) async {
      await pumpRail(tester, everything);
      await type(tester, 'contact');
      expect(find.text('Settings'), findsNothing);

      await tester.tap(find.byKey(const ValueKey('menu-search-clear')));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text('Settings'), findsOneWidget);
      expect(find.text('Dashboard'), findsOneWidget);
    });

  });

  group('choosing one of the rows a search left', () {
    /// A REAL router, because what these two assert is where a tap
    /// goes — and `context.go` against a `MaterialApp` with no router
    /// throws rather than navigating, so a harness without one asserts
    /// nothing about navigation at all.
    ///
    /// Every destination's path is served by the same builder, which
    /// hands `AppShell` the location it is actually at. That is what
    /// the app does, and it is what makes the selected row follow the
    /// page.
    Future<GoRouter> pumpRouted(
      WidgetTester tester, {
      bool grouped = false,
    }) async {
      tester.view.physicalSize = const Size(1400, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final router = GoRouter(
        initialLocation: '/dashboard',
        routes: [
          ShellRoute(
            builder: (context, state, child) =>
                AppShell(location: state.uri.path, child: child),
            routes: [
              GoRoute(
                path: '/:a',
                builder: (_, state) => Scaffold(
                  body: Text('at ${state.uri.path}'),
                ),
                routes: [
                  GoRoute(
                    path: ':b',
                    builder: (_, state) => Scaffold(
                      body: Text('at ${state.uri.path}'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ],
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            currentUserProvider.overrideWithValue(null),
            authStateProvider
                .overrideWith((_) => const Stream<AuthState>.empty()),
            isPlatformAdminProvider.overrideWith((_) async => false),
            organizationsProvider.overrideWith((_) async => [
                  Organization(
                    id: 'o1',
                    name: 'Sinar Teknologi Sdn Bhd',
                    slug: 'sinar',
                    baseCurrency: 'MYR',
                  ),
                ]),
            currentOrgProvider.overrideWith((_) async => null),
            enabledModulesProvider.overrideWith((_) async => everything),
            moduleLabelsProvider.overrideWith((_) async => labels),
            if (grouped) navGroupingProvider.overrideWith((_) async => true),
          ],
          child: MaterialApp.router(
            theme: AppTheme.light(),
            routerConfig: router,
          ),
        ),
      );
      await tester.pumpAndSettle();
      return router;
    }

    testWidgets('opens its own door, not whatever sat at that position',
        (tester) async {
      // The index bug, made visible. The grouped menu used to key every
      // row on its position in the UNFILTERED list; with one row left,
      // tapping it went wherever the first destination happened to be.
      // A query with SEVERAL results, and the one tapped deliberately
      // not the first: searching "payroll" leaves Payroll at the top,
      // so a row that always opened the first result would have passed
      // that and failed a real user. A mutation run said so.
      await pumpRouted(tester);
      await type(tester, 'people');
      expect(find.text('Payroll'), findsOneWidget);
      expect(find.text('HR setup'), findsOneWidget);

      await tester.tap(find.text('HR setup'));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text('at /hr/setup'), findsOneWidget);
    });

    testWidgets('and the grouped menu does the same', (tester) async {
      await pumpRouted(tester, grouped: true);
      await type(tester, 'people');

      await tester.tap(find.text('HR setup'));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text('at /hr/setup'), findsOneWidget);
    });

    testWidgets('and the box is cleared behind it', (tester) async {
      // The menu stays on screen after navigating. Left filtered down
      // to one row it reads as most of the product having been taken
      // away.
      await pumpRouted(tester);
      await type(tester, 'payroll');
      expect(find.text('Settings'), findsNothing);

      await tester.tap(find.text('Payroll'));
      await tester.pumpAndSettle();

      expect(find.text('Settings'), findsOneWidget);
      expect(find.text('Dashboard'), findsOneWidget);
    });
  });

  group('the side menu, grouped by module', () {
    /// 0293's switch. The grouped menu is a different widget from the
    /// plain rail, and it used to key every row on its INDEX in the
    /// unfiltered list — which a filter reorders and shortens.
    Widget groupedHarness(Set<String> modules) => ProviderScope(
          overrides: [
            currentUserProvider.overrideWithValue(null),
            authStateProvider
                .overrideWith((_) => const Stream<AuthState>.empty()),
            isPlatformAdminProvider.overrideWith((_) async => false),
            organizationsProvider.overrideWith((_) async => [
                  Organization(
                    id: 'o1',
                    name: 'Sinar Teknologi Sdn Bhd',
                    slug: 'sinar',
                    baseCurrency: 'MYR',
                  ),
                ]),
            currentOrgProvider.overrideWith((_) async => null),
            enabledModulesProvider.overrideWith((_) async => modules),
            moduleLabelsProvider.overrideWith((_) async => labels),
            navGroupingProvider.overrideWith((_) async => true),
          ],
          child: MaterialApp(
            theme: AppTheme.light(),
            home: const AppShell(
              location: '/dashboard',
              child: Scaffold(body: Text('body')),
            ),
          ),
        );

    Future<void> pumpGrouped(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1400, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(groupedHarness(everything));
      await tester.pumpAndSettle();
    }

    testWidgets('searches too, and drops the headings while it does',
        (tester) async {
      // Searching is not browsing. Headings over a list of three put
      // the answer further down the page than it needs to be, and a
      // ranked list cannot keep the groups whole anyway.
      await pumpGrouped(tester);
      expect(find.byKey(const ValueKey('menu-search')), findsOneWidget);

      await type(tester, 'contact');

      expect(tester.takeException(), isNull);
      expect(find.text('All Contacts'), findsOneWidget);
      expect(find.text('Settings'), findsNothing);
      // No headings left while a search is on. `RailHeading` upper-cases
      // them, so this is the heading as it is actually drawn.
      expect(find.text('BOOKS'), findsNothing);
      expect(find.text('PEOPLE'), findsNothing);
    });

    testWidgets('and the headings are back the moment the box is empty',
        (tester) async {
      await pumpGrouped(tester);
      expect(find.text('PEOPLE'), findsOneWidget);

      await type(tester, 'contact');
      expect(find.text('PEOPLE'), findsNothing);

      await tester.tap(find.byKey(const ValueKey('menu-search-clear')));
      await tester.pumpAndSettle();

      expect(find.text('PEOPLE'), findsOneWidget);
    });
  });

  group('the More sheet on a phone', () {
    Future<void> openSheet(WidgetTester tester, Set<String> modules) async {
      tester.view.physicalSize = const Size(412, 915);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(harness(modules));
      await tester.pumpAndSettle();
      await tester.tap(find.text('More'));
      await tester.pumpAndSettle();
    }

    testWidgets('searches as well, since it is the menu on a phone',
        (tester) async {
      await openSheet(tester, everything);
      expect(find.byKey(const ValueKey('menu-search')), findsOneWidget);

      await type(tester, 'timesheet');

      expect(tester.takeException(), isNull);
      expect(find.text('Timesheets'), findsOneWidget);
      expect(find.text('Settings'), findsNothing);
    });

    testWidgets('and searches the account rows alongside the doors',
        (tester) async {
      // Somebody typing "sign" means Sign out. A search that hid the
      // only row matching what was typed, while leaving it visible
      // underneath, would be worse than no search.
      await openSheet(tester, everything);
      await type(tester, 'sign out');

      expect(tester.takeException(), isNull);
      expect(find.text('Sign out'), findsOneWidget);
      expect(find.text('Settings'), findsNothing);
    });

    testWidgets('finds your own details by a word that is not in the label',
        (tester) async {
      await openSheet(tester, everything);
      await type(tester, 'password');

      expect(tester.takeException(), isNull);
      expect(find.text('Your details'), findsOneWidget);
    });

    testWidgets('a short sheet carries no box', (tester) async {
      await openSheet(tester, const {});
      expect(find.byKey(const ValueKey('menu-search')), findsNothing);
      expect(find.text('Sign out'), findsOneWidget);
    });

    testWidgets('and says so when nothing matches', (tester) async {
      await openSheet(tester, everything);
      await type(tester, 'xyzzy');

      expect(tester.takeException(), isNull);
      expect(find.text('Nothing in the menu matches that.'), findsOneWidget);
      expect(find.text('Sign out'), findsNothing);
    });
  });

  group('the matcher itself', () {
    // Pure, so the rule can be read without a shell around it.
    const rows = [
      (label: 'Payroll', group: 'People', path: '/payroll'),
      (label: 'Repayments', group: 'Banking', path: '/loans'),
      (label: 'HR setup', group: 'People', path: '/hr/setup'),
      (label: 'Ask about your books', group: '', path: '/ask'),
    ];

    List<String> found(String query) => menuMatches(
          rows,
          query,
          labelOf: (r) => r.label,
          keywordsOf: (r) => [r.group, r.path],
        ).map((r) => r.label).toList();

    test('an empty box is the whole menu, in menu order', () {
      expect(found(''), ['Payroll', 'Repayments', 'HR setup',
        'Ask about your books']);
      expect(found('   '), hasLength(4));
    });

    test('a label that starts with what was typed comes first', () {
      // "Repayments" contains "pay"; Payroll begins with it, and the
      // one you meant should not be under the one you did not.
      expect(found('pay').first, 'Payroll');
      expect(found('pay'), contains('Repayments'));
    });

    test('every word has to match, in any order', () {
      expect(found('setup hr'), ['HR setup']);
      expect(found('hr setup'), ['HR setup']);
      expect(found('hr accounts'), isEmpty);
    });

    test('the heading a door sits under is searched with it', () {
      // Typing a module's name brings up everything in it.
      expect(found('people'), ['Payroll', 'HR setup']);
    });

    test('and so is the route', () {
      expect(found('/loans'), ['Repayments']);
    });
  });
}
