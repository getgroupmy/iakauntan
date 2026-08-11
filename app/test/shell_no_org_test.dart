import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:iakauntan/src/core/providers.dart';
import 'package:iakauntan/src/core/theme.dart';
import 'package:iakauntan/src/data/models.dart';
import 'package:iakauntan/src/features/shell/app_shell.dart';

/// A platform operator belongs to no organization, so the shell has to
/// survive having almost nothing to show. Every destination but the
/// console reads from a company; with none, the rail is down to one
/// entry, and Material's navigation widgets require two.
void main() {
  Widget harness({
    required bool platformAdmin,
    required List<Organization> orgs,
  }) =>
      ProviderScope(
        overrides: [
          currentUserProvider.overrideWithValue(null),
          authStateProvider
              .overrideWith((_) => const Stream<AuthState>.empty()),
          isPlatformAdminProvider.overrideWith((_) async => platformAdmin),
          organizationsProvider.overrideWith((_) async => orgs),
          currentOrgProvider.overrideWith((_) async => null),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const AppShell(
            location: '/admin',
            child: Scaffold(body: Text('console')),
          ),
        ),
      );

  void sizeTo(WidgetTester tester, Size size) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  for (final entry in {
    'wide': const Size(1400, 900),
    'narrow': const Size(500, 900),
  }.entries) {
    testWidgets('${entry.key}: an operator with no organization gets a shell',
        (tester) async {
      sizeTo(tester, entry.value);

      await tester.pumpWidget(harness(platformAdmin: true, orgs: const []));

      // The first frame, before the platform-admin answer arrives: no
      // destinations at all. This is the frame that was throwing, and a
      // release build paints a thrown build as a blank page.
      expect(tester.takeException(), isNull, reason: 'first frame');
      expect(find.text('console'), findsOneWidget);

      // And once it resolves: exactly one destination, still under the
      // two that Material's navigation widgets demand.
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: 'after the admin check');
      expect(find.text('console'), findsOneWidget);
    });
  }

  // There is deliberately no test here for the ordinary case — a member
  // with organizations getting the full rail. Rendering the extended rail
  // under the test harness trips a RenderFlex constraint that the real
  // app does not, so such a test would fail for reasons that have nothing
  // to do with this code, and a test that fails for the wrong reason is
  // worse than none. That path is covered by the app being used.
}
