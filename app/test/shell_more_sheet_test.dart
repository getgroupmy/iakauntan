import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:iakauntan/src/core/providers.dart';
import 'package:iakauntan/src/core/theme.dart';
import 'package:iakauntan/src/data/models.dart';
import 'package:iakauntan/src/features/shell/app_shell.dart';

/// On a phone the rail is replaced by a bottom bar of four, and
/// everything else goes into a "More" sheet. With the modules switched on
/// that sheet holds seventeen entries plus Sign out, and a default modal
/// sheet is capped at a little over half the screen — so the list was cut
/// off mid-item with no way to scroll to the rest. Sign out, at the very
/// bottom, was unreachable.
void main() {
  Widget harness(Set<String> modules) => ProviderScope(
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

  /// A phone, in logical pixels: narrow enough for the bottom bar and
  /// short enough that the sheet cannot hold everything.
  Future<void> openSheet(WidgetTester tester, Set<String> modules) async {
    tester.view.physicalSize = const Size(412, 915);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(harness(modules));
    await tester.pumpAndSettle();

    await tester.tap(find.text('More'));
    await tester.pumpAndSettle();
  }

  testWidgets('every entry in the More sheet can be reached',
      (tester) async {
    await openSheet(tester, everything);
    expect(tester.takeException(), isNull);

    // Settings is near the bottom of the list, past where the sheet ends.
    final settings = find.text('Settings');
    expect(settings, findsOneWidget, reason: 'built, if not yet on screen');

    await tester.scrollUntilVisible(settings, 100,
        scrollable: find.byType(Scrollable).last);
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(settings, findsOneWidget);
  });

  testWidgets('sign out, the very last entry, is reachable', (tester) async {
    // The one that matters most: somebody who cannot reach it cannot
    // leave the account on a shared phone.
    await openSheet(tester, everything);

    final signOut = find.text('Sign out');
    await tester.scrollUntilVisible(signOut, 100,
        scrollable: find.byType(Scrollable).last);
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(tester.getRect(signOut).bottom, lessThanOrEqualTo(915));
  });

  testWidgets('a short list does not stretch the sheet to full height',
      (tester) async {
    // Nothing enabled: a handful of entries. Making the sheet scrollable
    // must not turn it into a full-screen page — you should still see
    // what you are leaving behind.
    await openSheet(tester, const {});
    expect(tester.takeException(), isNull);

    final sheet = tester.getRect(find.byType(BottomSheet));
    expect(sheet.height, lessThan(915 * 0.9));
  });
}
