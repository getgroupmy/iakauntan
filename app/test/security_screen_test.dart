import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:iakauntan/src/core/providers.dart';
import 'package:iakauntan/src/core/theme.dart';
import 'package:iakauntan/src/data/models.dart';
import 'package:iakauntan/src/features/shell/app_shell.dart';
import 'package:iakauntan/src/features/team/security_screen.dart';

/// Who is shown the security log.
///
/// The server is what decides — `security_log` and `audit_trail` both
/// refuse anybody who is not an owner or an admin — so what is asserted
/// here is that the screens agree, in both directions. A rail that hides
/// the door is only worth testing if something also proves the door is
/// there for the people who should have it; otherwise the same
/// assertions pass against a build that lost the feature entirely.
void main() {
  Widget shell(String role) => ProviderScope(
    overrides: [
      currentUserProvider.overrideWithValue(null),
      authStateProvider.overrideWith((_) => const Stream<AuthState>.empty()),
      isPlatformAdminProvider.overrideWith((_) async => false),
      organizationsProvider.overrideWith(
        (_) async => [
          Organization(
            id: 'o1',
            name: 'Kilang Selamat Sdn Bhd',
            slug: 'kilang',
            baseCurrency: 'MYR',
          ),
        ],
      ),
      currentOrgProvider.overrideWith((_) async => null),
      enabledModulesProvider.overrideWith(
        (_) async => const {'sales', 'accounting', 'contacts'},
      ),
      memberRoleProvider.overrideWith((_) async => role),
    ],
    child: MaterialApp(
      theme: AppTheme.light(),
      home: const AppShell(
        location: '/',
        child: Scaffold(body: Text('body')),
      ),
    ),
  );

  Widget screen(String role) => ProviderScope(
    overrides: [
      currentUserProvider.overrideWithValue(null),
      authStateProvider.overrideWith((_) => const Stream<AuthState>.empty()),
      currentOrgProvider.overrideWith((_) async => null),
      memberRoleProvider.overrideWith((_) async => role),
      securitySummaryProvider.overrideWith(
        (_) async => const {
          'sign_ins': 1284,
          'people': 37,
          'addresses': 112,
          'failed_sign_ins': 9,
          'exports': 46,
          'reads': 318,
          'changes': 5120,
          'denials': 27,
        },
      ),
      securityLogProvider.overrideWith((_, _) async => const []),
      auditTrailProvider.overrideWith((_) async => const []),
    ],
    child: MaterialApp(
      theme: AppTheme.light(),
      home: const SecurityScreen(),
    ),
  );

  Future<void> onADesktop(WidgetTester tester, Widget widget) async {
    tester.view.physicalSize = const Size(1400, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(widget);
    await tester.pumpAndSettle();
  }

  testWidgets('an owner is shown the way to the security log', (tester) async {
    await onADesktop(tester, shell('owner'));
    expect(find.text('Security'), findsOneWidget);
  });

  testWidgets('a clerk is not, and still has the rest of the rail', (
    tester,
  ) async {
    await onADesktop(tester, shell('accounts_clerk'));
    expect(find.text('Security'), findsNothing);

    // The positive control: without this, the assertion above would also
    // hold for a rail that failed to build anything at all.
    expect(find.text('Team'), findsOneWidget);
    expect(find.text('Settings'), findsOneWidget);
  });

  testWidgets('and is told why, rather than shown an error', (tester) async {
    await onADesktop(tester, screen('accounts_clerk'));
    expect(find.text('Only an owner or an admin'), findsOneWidget);

    // Nothing was asked of the server, so nothing can have failed.
    expect(tester.takeException(), isNull);
  });

  /// The four figures at the top, on a phone. A grid of fixed shape gave
  /// each tile 102 pixels at 360 for three lines that need 118; the
  /// rows are as tall as their tiles now (`TileGrid`).
  for (final width in [360.0, 412.0, 1100.0]) {
    testWidgets('the figures fit at ${width.toInt()}', (tester) async {
      tester.view.physicalSize = Size(width, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(screen('owner'));
      await tester.pumpAndSettle();

      final card = find
          .ancestor(of: find.text('Sign-ins'), matching: find.byType(Card))
          .first;
      final ink = tester.getRect(
        find.descendant(of: card, matching: find.byType(InkWell)).first,
      );
      final content = tester.getRect(
        find.descendant(of: card, matching: find.byType(Column)).first,
      );
      // The tile holds all of its content, caption included.
      expect(find.text('37 people, 112 addresses'), findsOneWidget);
      expect(ink.bottom - content.bottom, greaterThanOrEqualTo(Space.lg));
    });
  }
}
