import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:iakauntan/src/core/providers.dart';
import 'package:iakauntan/src/core/theme.dart';
import 'package:iakauntan/src/data/models.dart';
import 'package:iakauntan/src/features/shell/app_shell.dart';

/// With every module switched on the rail has twenty-one destinations,
/// which is taller than a laptop screen. NavigationRail does not scroll,
/// so everything past the fold was simply unreachable — and silently so,
/// with no scrollbar to hint that the list continued.
void main() {
  Widget harness(Set<String> modules) => ProviderScope(
        overrides: [
          currentUserProvider.overrideWithValue(null),
          authStateProvider
              .overrideWith((_) => const Stream<AuthState>.empty()),
          isPlatformAdminProvider.overrideWith((_) async => true),
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
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const AppShell(
            location: '/',
            child: Scaffold(body: Text('body')),
          ),
        ),
      );

  /// Every module, including the core three. Since 0234 tagged the
  /// destinations that used to carry no module at all — Sales, Journals,
  /// Reports and the rest — a set without `sales`, `accounting` and
  /// `contacts` is a *short* rail, which is the opposite of what these
  /// two tests are for.
  const everything = {
    'sales', 'accounting', 'contacts',
    'purchases', 'legal', 'inventory', 'crm', 'einvoice',
    'hr', 'payroll', 'secretarial', 'fixed_assets',
    'pos', 'ticketing', 'timesheets', 'property_strata',
    'approvals', 'mbrs', 'forecasting', 'chat', 'manufacturing',
  };

  testWidgets('the last destination is reachable on a short screen',
      (tester) async {
    // Deliberately shorter than the rail is tall.
    tester.view.physicalSize = const Size(1400, 500);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(harness(everything));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    // Settings is the second to last entry, well past the fold.
    final settings = find.text('Settings');
    expect(settings, findsOneWidget,
        reason: 'built, even if it is not on screen yet');

    await tester.scrollUntilVisible(settings, 120,
        scrollable: find.byType(Scrollable).first);
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(settings, findsOneWidget);
  });

  testWidgets('a short rail still fills the height', (tester) async {
    // THE HEIGHT IS MEASURED, NOT GUESSED, and that is the fourth
    // version of this test.
    //
    // It was 1200, then 1600, then 2000, and each time a destination
    // that carries no module gate was added the ungated rail grew past
    // the number and this test quietly started measuring the OTHER case
    // — a rail that scrolls, which the assertion at the bottom is not
    // about. 1200 went when a gateless destination arrived, 1600 when
    // `Your details` was added beside Settings, and 2000 when `0721`
    // added Users and Support access to the console. The previous
    // version of this comment said that a fourth time meant deriving the
    // number from the rail's own height. This is that.
    //
    // Two passes: ask the rail how tall it wants to be, then give it
    // that much and some. A destination added tomorrow moves the first
    // measurement and the second follows it.
    Future<double> overflowAt(double height) async {
      tester.view.physicalSize = Size(1400, height);
      tester.view.devicePixelRatio = 1.0;
      await tester.pumpWidget(harness(const {}));
      await tester.pumpAndSettle();

      // The scroll view is OUTSIDE the rail, not inside it:
      // `NavigationRail` does not scroll, so the shell wraps it in a
      // `SingleChildScrollView` with a minimum height of the viewport.
      // So this is an ancestor finder, and the nearest one is the rail's.
      final scrollable = find
          .ancestor(
            of: find.byType(NavigationRail),
            matching: find.byType(Scrollable),
          )
          .first;
      // How much of the rail did not fit. Zero means it all did, which
      // is the case this test is for.
      return tester.state<ScrollableState>(scrollable).position
          .maxScrollExtent;
    }

    addTearDown(tester.view.reset);

    // Deliberately too short, so there is an overflow to measure. Its
    // exact value does not matter: whatever did not fit is added back.
    const probe = 800.0;
    final missing = await overflowAt(probe);
    // 120 of headroom on top of what the rail asked for, so the case
    // being tested is a rail with room to spare rather than one that
    // exactly fills the window.
    final tall = probe + missing + 120;

    expect(await overflowAt(tall), 0.0,
        reason: 'the whole rail fits, which is the case under test');
    expect(tester.takeException(), isNull);
    expect(find.byType(NavigationRail), findsOneWidget);

    // The rail reaches the bottom of the window rather than shrink-
    // wrapping its handful of destinations. That is what `trailing:
    // Expanded` needs a bounded height for, and it is the part the
    // scroll view would otherwise have collapsed.
    expect(tester.getRect(find.byType(NavigationRail)).bottom, tall);
  });
}
