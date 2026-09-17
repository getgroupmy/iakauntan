import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:iakauntan/src/core/providers.dart';
import 'package:iakauntan/src/core/theme.dart';
import 'package:iakauntan/src/data/models.dart';
import 'package:iakauntan/src/data/platform_catalog_repository.dart';
import 'package:iakauntan/src/features/dashboard/dashboard_screen.dart';
import 'package:iakauntan/src/features/shell/app_shell.dart';

/// What a company that only does one thing is shown.
///
/// The rule 0234 added is on the server and asserted in
/// `supabase/tests/module_surface.sql`. What is asserted here is the half
/// the customer actually sees: a firm that runs a service desk and keeps
/// no books gets a rail of service desk screens and a dashboard made of
/// tickets, rather than nineteen accounting destinations and four
/// figures that are all zero.
///
/// Both halves are asserted in both directions. A test that only checks
/// what is hidden passes just as well against a shell that renders
/// nothing at all, so every case names something that must still be
/// there — Settings above all, because it is where a module that has
/// been put away is taken out again, and hiding it would lock the door
/// behind whoever pressed the switch.
void main() {
  Widget shell(Set<String> modules) => ProviderScope(
    overrides: [
      currentUserProvider.overrideWithValue(null),
      authStateProvider.overrideWith((_) => const Stream<AuthState>.empty()),
      isPlatformAdminProvider.overrideWith((_) async => false),
      organizationsProvider.overrideWith(
        (_) async => [
          Organization(
            id: 'o1',
            name: 'Meja Bantuan Sdn Bhd',
            slug: 'meja',
            baseCurrency: 'MYR',
          ),
        ],
      ),
      currentOrgProvider.overrideWith((_) async => null),
      enabledModulesProvider.overrideWith((_) async => modules),
    ],
    child: MaterialApp(
      theme: AppTheme.light(),
      home: const AppShell(
        location: '/',
        child: Scaffold(body: Text('body')),
      ),
    ),
  );

  /// The dashboard with the entitlements known and the platform
  /// catalogue deliberately left out.
  ///
  /// That is not laziness — it is the state the screen is actually in
  /// for the first frames of every sign-in, and it used to render the
  /// "every module is switched off" empty state over a company that
  /// held three. Leaving [labels] null here keeps a widget-level guard
  /// on that; pass one to assert what the tabs are called.
  Widget dashboard({
    required Set<String> modules,
    required Map<String, dynamic> figures,
    Map<String, ({String name, String group})>? labels,
    List<String>? panels,
  }) => ProviderScope(
    overrides: [
      currentUserProvider.overrideWithValue(null),
      authStateProvider.overrideWith((_) => const Stream<AuthState>.empty()),
      currentOrgProvider.overrideWith(
        (_) async => Organization(
          id: 'o1',
          name: 'Meja Bantuan Sdn Bhd',
          slug: 'meja',
          baseCurrency: 'MYR',
        ),
      ),
      enabledModulesProvider.overrideWith((_) async => modules),
      moduleDashboardProvider.overrideWith((_) async => figures),
      if (labels != null)
        moduleLabelsProvider.overrideWith((_) async => labels),
      if (panels != null)
        userPreferencesProvider.overrideWith(
          (_) async => UserPreferences(dashboardCards: panels),
        ),
    ],
    child: MaterialApp(
      theme: AppTheme.light(),
      home: const DashboardScreen(),
    ),
  );

  Future<void> onADesktop(WidgetTester tester, Widget widget) async {
    tester.view.physicalSize = const Size(1400, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(widget);
    await tester.pumpAndSettle();
  }

  /// Go and ask for a module's own dashboard.
  ///
  /// Which is now a deliberate act rather than where the screen lands.
  /// The strip of tabs this replaced scrolled sideways off the edge of
  /// a phone and put whichever module sorted first in front of
  /// everybody; the landing page is the same for all of them now, and a
  /// module dashboard is chosen by name from one box.
  ///
  /// [named] is what the picker calls it — the platform's name for the
  /// module when the catalogue has arrived, and the bare code when it
  /// has not.
  Future<void> show(WidgetTester tester, String named) async {
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('dashboard-view')),
        matching: find.byType(TextField),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(of: find.byType(ListTile), matching: find.text(named)),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('a service desk company is not shown the ledger', (tester) async {
    await onADesktop(tester, shell(const {'ticketing', 'contacts'}));

    // What it pays for, and the screens every company keeps.
    expect(find.text('Service desk'), findsOneWidget);
    expect(find.text('Settings'), findsOneWidget);
    expect(find.text('Team'), findsOneWidget);

    // Contacts is four entries now, not one: the split into Customer,
    // Supplier and Prospect put three doors beside All Contacts, and
    // this assertion used to look for a nav item called exactly
    // "Contacts" — which is nobody's label any more.
    expect(find.text('All Contacts'), findsOneWidget);
    expect(find.text('Customer'), findsOneWidget);
    expect(find.text('Supplier'), findsOneWidget);
    expect(find.text('Prospect'), findsOneWidget);

    // What it does not. These carried no module tag at all before 0234
    // and were shown to every company on the platform.
    expect(find.text('Sales'), findsNothing);
    expect(find.text('Journals'), findsNothing);
    expect(find.text('Reconcile'), findsNothing);
    expect(find.text('Fixed assets'), findsNothing);
    expect(find.text('Withholding tax'), findsNothing);
    expect(find.text('Reports'), findsNothing);
    expect(find.text('Exchange rates'), findsNothing);

    // The assistant is a module like any other. It is the newest one
    // here and the easiest to leave ungated, because its whole surface
    // is a single screen and a single screen is easy to hang off the
    // bottom of the list without a tag.
    expect(find.text('Ask about your books'), findsNothing);
  });

  testWidgets('a company that bought the assistant gets its door', (
    tester,
  ) async {
    // The other half. Asserting only the absence above would pass just
    // as well against a destination nobody ever added, which is the
    // state 0470 actually left this in.
    await onADesktop(tester, shell(const {'ai', 'contacts'}));
    expect(find.text('Ask about your books'), findsOneWidget);
  });

  testWidgets('a company that keeps books still gets all of it', (
    tester,
  ) async {
    // The positive control. Without it every assertion above is also
    // satisfied by a rail that renders nothing.
    await onADesktop(
      tester,
      shell(const {'sales', 'accounting', 'contacts', 'fixed_assets'}),
    );

    expect(find.text('Sales'), findsOneWidget);
    expect(find.text('Journals'), findsOneWidget);
    expect(find.text('Reconcile'), findsOneWidget);
    expect(find.text('Fixed assets'), findsOneWidget);
    expect(find.text('Reports'), findsOneWidget);
    expect(find.text('Service desk'), findsNothing);
  });

  testWidgets('the dashboard is made of tickets, not takings', (tester) async {
    await onADesktop(
      tester,
      dashboard(
        modules: const {'ticketing'},
        figures: const {
          'ticketing': {
            'open': 7,
            'unassigned': 2,
            'breaching': 5,
            'breached': 3,
            'resolved_today': 4,
          },
        },
      ),
    );

    // The landing page is the Overview, the same for everybody. The
    // ticket figures are a module dashboard, and somebody has to ask.
    expect(find.byType(ModuleDashboardPane), findsNothing);
    expect(find.text('Open tickets'), findsNothing);

    await show(tester, 'ticketing');

    expect(find.text('Open tickets'), findsOneWidget);
    expect(find.text('7'), findsOneWidget);
    expect(find.text('2 unassigned'), findsOneWidget);
    expect(find.text('Against the clock'), findsOneWidget);
    expect(find.text('3 already past due'), findsOneWidget);
    expect(find.text('Resolved today'), findsOneWidget);

    // The accounting dashboard is not merely empty, it is absent: with
    // `accounting` off there is nothing to ask the ledger for.
    expect(find.text('Revenue this month'), findsNothing);
    expect(find.text('Bank balance'), findsNothing);
    expect(find.text('Receivables'), findsNothing);
  });

  testWidgets('the picker names modules by the platform, not by their codes', (
    tester,
  ) async {
    // The other half. Above, the catalogue is missing and the company
    // can still reach its dashboard; here it has arrived and the row
    // carries the name the console gave the module rather than
    // `ticketing`. Which matters more now than it did under the tabs:
    // the name is what somebody types to find it.
    await onADesktop(
      tester,
      dashboard(
        modules: const {'ticketing'},
        figures: const {
          'ticketing': {'open': 7, 'unassigned': 2, 'breaching': 5,
                        'breached': 3, 'resolved_today': 4},
        },
        labels: const {
          'ticketing': (name: 'Service desk', group: 'Service desk'),
        },
      ),
    );

    await show(tester, 'Service desk');

    expect(find.text('ticketing'), findsNothing);
    expect(find.text('Open tickets'), findsOneWidget);
  });

  testWidgets('the pipeline says when it could not add everything up', (
    tester,
  ) async {
    // 0303 does not convert currencies, because the rate lookup raises
    // when there is no rate and would take every other module's figures
    // down with it. The consequence is that `open_value` can be short,
    // and the tile has to say so — a total that silently leaves out the
    // biggest deal in the pipeline is worse than no total.
    await onADesktop(
      tester,
      dashboard(
        modules: const {'crm'},
        figures: const {
          'crm': {
            'open_deals': 5,
            'open_value': 10000,
            'other_currency': 2,
            'closing_this_month': 3,
            'won_this_month': 1,
            'overdue_activities': 4,
          },
        },
      ),
    );

    await show(tester, 'crm');

    expect(find.text('Open deals'), findsOneWidget);
    expect(find.text('5'), findsOneWidget);
    expect(
      find.textContaining('plus 2 in other currencies'),
      findsOneWidget,
    );
    expect(find.text('Follow-ups overdue'), findsOneWidget);
    expect(find.text('Somebody is waiting'), findsOneWidget);
  });

  testWidgets('and shows a plain total when there is nothing left out', (
    tester,
  ) async {
    // The control. Without it the caption above is also satisfied by a
    // tile that appends the warning to every company on the platform.
    await onADesktop(
      tester,
      dashboard(
        modules: const {'crm'},
        figures: const {
          'crm': {
            'open_deals': 5,
            'open_value': 10000,
            'other_currency': 0,
            'closing_this_month': 3,
            'won_this_month': 1,
            'overdue_activities': 0,
          },
        },
      ),
    );

    await show(tester, 'crm');

    expect(find.textContaining('other currencies'), findsNothing);
    expect(find.text('Nothing owed'), findsOneWidget);
  });

  testWidgets('the Registrar tile names the date, not a count of days', (
    tester,
  ) async {
    // A secretary works to a calendar. "14 Sep 2026" goes in the diary;
    // "in 22 days" has to be converted before it is any use, and is
    // wrong by one the moment the page has been open past midnight.
    await onADesktop(
      tester,
      dashboard(
        modules: const {'secretarial'},
        figures: const {
          'secretarial': {
            'overdue': 2,
            'due_soon': 4,
            'next_due': '2026-09-14',
            'entities': 31,
          },
        },
      ),
    );

    await show(tester, 'secretarial');

    expect(find.text('Past their deadline'), findsOneWidget);
    expect(find.text('2'), findsOneWidget);
    expect(find.text('Lodge these first'), findsOneWidget);
    // The whole caption, formatted. An earlier version of this looked
    // for a substring "2026", which also matched the greeting's own
    // date at the top of the tab — a finder loose enough to be
    // satisfied by the wrong widget is not asserting the thing it
    // names. `Fmt.date` is dd/MM/yyyy.
    expect(find.text('Next on 14/09/2026'), findsOneWidget);
    expect(find.text('31'), findsOneWidget);
  });

  testWidgets('and says so plainly when nothing is owed', (tester) async {
    // The control, and the state most practices are in most of the
    // time. Without it, every assertion above is also satisfied by a
    // tile that shouts at a firm that is perfectly up to date.
    await onADesktop(
      tester,
      dashboard(
        modules: const {'secretarial'},
        figures: const {
          'secretarial': {
            'overdue': 0,
            'due_soon': 0,
            'next_due': null,
            'entities': 31,
          },
        },
      ),
    );

    await show(tester, 'secretarial');

    expect(find.text('Nothing is late'), findsOneWidget);
    expect(find.text('Nothing in the next month'), findsOneWidget);
    expect(find.textContaining('Next on'), findsNothing);
  });

  testWidgets('a company with no module at all still gets a landing page', (
    tester,
  ) async {
    // What changed when the tabs went. A company holding nothing used
    // to be sent straight to an empty state, because there was no first
    // tab to land on. The landing page is not a module's now — it is
    // the to-do list and the ticker, which belong to nobody in
    // particular — so it is still there, and there is nothing to pick
    // between, so there is no box either.
    await onADesktop(tester, dashboard(modules: const {}, figures: const {}));

    expect(find.text('Nothing to show yet'), findsNothing);
    expect(find.byKey(const ValueKey('dashboard-view')), findsNothing);
    expect(find.byType(ModuleDashboardPane), findsNothing);
  });

  testWidgets('and is told so only when it has emptied the page itself', (
    tester,
  ) async {
    // The one case left where there is genuinely nothing to draw: no
    // module, and both panels switched off under Settings > Landing
    // page. A greeting over white space reads as broken, so it says so
    // and names both ways back.
    await onADesktop(
      tester,
      dashboard(modules: const {}, figures: const {}, panels: const []),
    );

    expect(find.text('Nothing to show yet'), findsOneWidget);
  });

  testWidgets('the landing page is the same one for a company holding six', (
    tester,
  ) async {
    // The point of the change. Whatever a company bought, everybody
    // lands on the same page; the modules are behind one box, in
    // platform order, under a name they can search.
    await onADesktop(
      tester,
      dashboard(
        modules: const {'ticketing', 'crm', 'secretarial'},
        figures: const {},
        labels: const {
          'crm': (name: 'Sales pipeline', group: 'Sales'),
          'ticketing': (name: 'Service desk', group: 'Service desk'),
          'secretarial': (name: 'Registrar', group: 'Secretarial'),
        },
      ),
    );

    expect(find.byType(ModuleDashboardPane), findsNothing);
    expect(find.byKey(const ValueKey('dashboard-view')), findsOneWidget);

    // And the box is the way to one, found by typing the code rather
    // than the name — which is what somebody who knows the product
    // types.
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('dashboard-view')),
        matching: find.byType(TextField),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.descendant(
        of: find.byKey(const ValueKey('dashboard-view')),
        matching: find.byType(TextField),
      ),
      'crm',
    );
    await tester.pumpAndSettle();

    // Only the one row, and it is the one named for people rather than
    // the code that found it.
    expect(
      find.descendant(of: find.byType(ListTile), matching: find.text('Sales pipeline')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: find.byType(ListTile), matching: find.text('Registrar')),
      findsNothing,
    );

    await tester.tap(
      find.descendant(
        of: find.byType(ListTile),
        matching: find.text('Sales pipeline'),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(ModuleDashboardPane), findsOneWidget);
  });
}
