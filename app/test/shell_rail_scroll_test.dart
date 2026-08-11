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

  const everything = {
    'purchases', 'legal', 'inventory', 'crm', 'einvoice',
    'hr', 'payroll', 'secretarial',
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
    tester.view.physicalSize = const Size(1400, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    // Nothing enabled: only the ungated destinations plus the console.
    await tester.pumpWidget(harness(const {}));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.byType(NavigationRail), findsOneWidget);

    // The rail reaches the bottom of the window rather than shrink-
    // wrapping its handful of destinations. That is what `trailing:
    // Expanded` needs a bounded height for, and it is the part the
    // scroll view would otherwise have collapsed.
    expect(tester.getRect(find.byType(NavigationRail)).bottom, 1200);
  });
}
