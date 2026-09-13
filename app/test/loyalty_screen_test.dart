import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:iakauntan/src/core/providers.dart';
import 'package:iakauntan/src/core/theme.dart';
import 'package:iakauntan/src/data/models.dart';
import 'package:iakauntan/src/features/loyalty/loyalty_screen.dart';
import 'package:iakauntan/src/features/shell/app_shell.dart';

/// Points are a ledger, and somebody has to be able to look at it.
///
/// The rules are the server's: an owner or admin may adjust, an
/// adjustment needs a reason, and the dormancy sweep clears only what
/// has been quiet long enough. What is asserted here is the split a
/// person sees — because handing out points is handing out money, and a
/// screen that offered the button to everybody would be inviting a
/// refusal rather than describing a control.
void main() {
  Widget screen({
    required bool isAdmin,
    Set<String> modules = const {'loyalty'},
  }) => ProviderScope(
    overrides: [
      currentUserProvider.overrideWithValue(null),
      authStateProvider.overrideWith((_) => const Stream<AuthState>.empty()),
      currentOrgProvider.overrideWith(
        (_) async => Organization(
          id: 'o1',
          name: 'Kedai Runcit Sdn Bhd',
          slug: 'runcit',
          baseCurrency: 'MYR',
        ),
      ),
      enabledModulesProvider.overrideWith((_) async => modules),
      canAdminProvider.overrideWithValue(isAdmin),
    ],
    child: MaterialApp(theme: AppTheme.light(), home: const LoyaltyScreen()),
  );

  Future<void> show(WidgetTester tester, Widget widget) async {
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(widget);
    await tester.pumpAndSettle();
  }

  testWidgets('an admin is offered the dormancy sweep', (tester) async {
    // The sweep had no caller and is on no schedule, so a shop that set
    // a dormancy period has points that never expire. This button is
    // the whole reason the screen exists.
    await show(tester, screen(isAdmin: true));
    expect(find.text('Expire dormant'), findsOneWidget);
  });

  testWidgets('somebody who is not an admin is not', (tester) async {
    // Taking points off named customers is not a counter job.
    await show(tester, screen(isAdmin: false));
    expect(find.text('Expire dormant'), findsNothing);
    // The positive control: the screen itself still rendered, so
    // "not found" is an answer rather than a blank page.
    expect(find.text('Find a member'), findsOneWidget);
  });

  testWidgets('the sweep asks before it takes anything away', (tester) async {
    await show(tester, screen(isAdmin: true));
    await tester.tap(find.text('Expire dormant'));
    await tester.pumpAndSettle();

    expect(find.text('Expire dormant points'), findsOneWidget);
    expect(find.textContaining('their points are gone'), findsOneWidget);
    // And can be backed out of.
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('Expire dormant points'), findsNothing);
  });

  testWidgets('a company without the module gets no screen', (tester) async {
    await show(tester, screen(isAdmin: true, modules: const {'pos'}));
    expect(find.text('Loyalty is not switched on'), findsOneWidget);
    expect(find.text('Expire dormant'), findsNothing);
  });

  testWidgets('the rail offers loyalty only to a company that has it', (
    tester,
  ) async {
    Widget shell(Set<String> modules) => ProviderScope(
      overrides: [
        currentUserProvider.overrideWithValue(null),
        authStateProvider.overrideWith((_) => const Stream<AuthState>.empty()),
        isPlatformAdminProvider.overrideWith((_) async => false),
        organizationsProvider.overrideWith(
          (_) async => [
            Organization(
              id: 'o1',
              name: 'Kedai Runcit Sdn Bhd',
              slug: 'runcit',
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

    tester.view.physicalSize = const Size(1400, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(shell(const {'pos', 'loyalty'}));
    await tester.pumpAndSettle();

    expect(find.text('Loyalty'), findsOneWidget);
    // A gym runs memberships and no points card; the two were split in
    // 0231 precisely so a shop takes one without the other.
    expect(find.text('Memberships'), findsNothing);
  });

  /// The dormancy the sweep acts on and no screen ever showed.
  ///
  /// `loyalty_account_balance` has carried `last_activity` since 0212,
  /// `loyaltyAccountBalanceProvider` wrapped it, this screen
  /// invalidated it after every adjustment — and nothing read it. The
  /// list comes from `loyalty_lookup`, which has the points and their
  /// worth but not when the account was last active. So the button in
  /// this screen's own app bar took points away on a basis the screen
  /// could not show.
  ///
  /// Which accounts the sweep actually clears is the database's, in
  /// `supabase/tests/pos_loyalty.sql`. What is asserted here is the
  /// sentence beside the balance.
  group('loyaltyLastActive', () {
    final now = DateTime(2026, 9, 13);

    test('an account nothing has ever moved on is not called dormant', () {
      // Enrolled this morning, no purchase yet. "Last active —" would
      // read as very quiet indeed.
      expect(
        loyaltyLastActive(null, now: now),
        'No points have moved on this account yet',
      );
    });

    test('the recent past is said in days', () {
      expect(
        loyaltyLastActive(DateTime(2026, 9, 13), now: now),
        'Last active today',
      );
      expect(
        loyaltyLastActive(DateTime(2026, 9, 12), now: now),
        'Last active yesterday',
      );
      expect(
        loyaltyLastActive(DateTime(2026, 8, 30), now: now),
        'Last active 30/08/2026 — 14 days ago',
      );
    });

    test('and the far past in months, approximately and admittedly so', () {
      // A shopkeeper deciding whether to sweep needs "about eight
      // months", not "247 days".
      final line = loyaltyLastActive(DateTime(2026, 1, 9), now: now);
      expect(line, contains('09/01/2026'));
      expect(line, contains('about 8 months ago'));
      expect(line, isNot(contains('247')));
    });

    test('the boundary between the two is sixty days', () {
      expect(
        loyaltyLastActive(now.subtract(const Duration(days: 59)), now: now),
        contains('59 days ago'),
      );
      expect(
        loyaltyLastActive(now.subtract(const Duration(days: 60)), now: now),
        contains('about 2 months ago'),
      );
    });
  });
}
