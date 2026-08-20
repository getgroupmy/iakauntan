import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:iakauntan/src/core/providers.dart';
import 'package:iakauntan/src/core/theme.dart';
import 'package:iakauntan/src/data/models.dart';
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

  Widget dashboard({
    required Set<String> modules,
    required Map<String, dynamic> figures,
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

  testWidgets('a service desk company is not shown the ledger', (tester) async {
    await onADesktop(tester, shell(const {'ticketing', 'contacts'}));

    // What it pays for, and the two screens every company keeps.
    expect(find.text('Service desk'), findsOneWidget);
    expect(find.text('Contacts'), findsOneWidget);
    expect(find.text('Settings'), findsOneWidget);
    expect(find.text('Team'), findsOneWidget);

    // What it does not. These carried no module tag at all before 0234
    // and were shown to every company on the platform.
    expect(find.text('Sales'), findsNothing);
    expect(find.text('Journals'), findsNothing);
    expect(find.text('Reconcile'), findsNothing);
    expect(find.text('Fixed assets'), findsNothing);
    expect(find.text('Withholding tax'), findsNothing);
    expect(find.text('Reports'), findsNothing);
    expect(find.text('Exchange rates'), findsNothing);
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

  testWidgets('a company with no module at all is told so, not left blank', (
    tester,
  ) async {
    await onADesktop(
      tester,
      dashboard(modules: const {}, figures: const {}),
    );

    expect(find.text('Nothing to show yet'), findsOneWidget);
  });
}
