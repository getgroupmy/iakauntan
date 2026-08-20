import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:iakauntan/src/core/providers.dart';
import 'package:iakauntan/src/core/theme.dart';
import 'package:iakauntan/src/data/models.dart';
import 'package:iakauntan/src/features/pos/memberships_screen.dart';
import 'package:iakauntan/src/features/shell/app_shell.dart';

/// Reaching the memberships that 0218 built and nothing ever called.
///
/// The rules are the server's and are asserted in SQL. What is asserted
/// here is the part a person sees, and in particular the two things this
/// screen exists to get right:
///
///   * unlimited is not zero — a null `included` means the membership
///     covers everything, and telling somebody on an unlimited gym
///     membership that they have nothing left is the failure worth a
///     test;
///   * the billing gaps are shown without being asked for, because
///     `start_membership` trades a refusal at the counter for a report,
///     and a report nobody sees is the same as the refusal.
void main() {
  Widget screen({
    required Set<String> modules,
    List<Map<String, dynamic>> subscriptions = const [],
    List<Map<String, dynamic>> gaps = const [],
    Map<String, dynamic>? balance,
  }) => ProviderScope(
    overrides: [
      currentUserProvider.overrideWithValue(null),
      authStateProvider.overrideWith((_) => const Stream<AuthState>.empty()),
      currentOrgProvider.overrideWith(
        (_) async => Organization(
          id: 'o1',
          name: 'Gim Sihat Sdn Bhd',
          slug: 'gim',
          baseCurrency: 'MYR',
        ),
      ),
      enabledModulesProvider.overrideWith((_) async => modules),
      membershipSubscriptionsProvider.overrideWith((_, __) async => subscriptions),
      membershipBillingGapsProvider.overrideWith((_) async => gaps),
      membershipBalanceProvider.overrideWith((_, __) async => balance),
    ],
    child: MaterialApp(
      theme: AppTheme.light(),
      home: const MembershipsScreen(),
    ),
  );

  Map<String, dynamic> subscription({
    String id = 's1',
    String member = 'Aisyah Rahman',
    String offer = 'Unlimited gym',
    String status = 'active',
    String? recurring = 'r1',
  }) => {
    'id': id,
    'started_on': '2026-01-20',
    'ends_on': null,
    'status': status,
    'note': null,
    'recurring_document_id': recurring,
    'contacts': {'name': member},
    'pos_memberships': {
      'name': offer,
      'period': 'monthly',
      'sessions_included': null,
    },
  };

  Future<void> show(WidgetTester tester, Widget widget) async {
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(widget);
    await tester.pumpAndSettle();
  }

  testWidgets('unlimited is shown as unlimited, not as nothing left', (
    tester,
  ) async {
    await show(
      tester,
      screen(
        modules: const {'memberships'},
        subscriptions: [subscription()],
        // What `membership_balance` returns for an unlimited
        // membership: included and remaining are null, used is real.
        balance: const {
          'membership': 'Unlimited gym',
          'status': 'active',
          'period_start': '2026-08-20',
          'period_end': '2026-09-19',
          'included': null,
          'used': 6,
          'remaining': null,
        },
      ),
    );

    expect(find.text('Aisyah Rahman'), findsOneWidget);
    expect(find.textContaining('unlimited'), findsOneWidget);
    // The failure this test exists for: null read as zero.
    expect(find.textContaining('0 left'), findsNothing);
  });

  testWidgets('a counted membership says how many are left', (tester) async {
    // The positive control for the case above. Without it, a screen that
    // printed "unlimited" for every membership would also pass.
    await show(
      tester,
      screen(
        modules: const {'memberships'},
        subscriptions: [subscription(offer: 'Ten classes')],
        balance: const {
          'membership': 'Ten classes',
          'status': 'active',
          'period_start': '2026-08-20',
          'period_end': '2026-09-19',
          'included': 10,
          'used': 7,
          'remaining': 3,
        },
      ),
    );

    expect(find.textContaining('7 of 10 used'), findsOneWidget);
    expect(find.textContaining('3 left'), findsOneWidget);
    expect(find.textContaining('unlimited'), findsNothing);
  });

  testWidgets('the memberships nobody is billing are on screen', (
    tester,
  ) async {
    await show(
      tester,
      screen(
        modules: const {'memberships'},
        subscriptions: [subscription(recurring: null)],
        gaps: const [
          {
            'subscription_id': 's1',
            'member': 'Aisyah Rahman',
            'membership': 'Unlimited gym',
            'started_on': '2026-01-20',
            'next_period_starts': '2026-09-20',
          },
        ],
      ),
    );

    expect(
      find.textContaining('1 membership has no renewal schedule'),
      findsOneWidget,
    );
    expect(find.text('No renewal schedule'), findsOneWidget);
  });

  testWidgets('no banner when every membership is billed', (tester) async {
    // The other half. An assertion that only checks the banner appears
    // is satisfied by a banner that is always there.
    await show(
      tester,
      screen(
        modules: const {'memberships'},
        subscriptions: [subscription()],
      ),
    );

    expect(find.textContaining('no renewal schedule'), findsNothing);
    expect(find.text('Aisyah Rahman'), findsOneWidget);
  });

  testWidgets('a company without the module gets no screen and no nav', (
    tester,
  ) async {
    await show(
      tester,
      screen(modules: const {'pos'}, subscriptions: [subscription()]),
    );

    expect(find.text('Memberships is not switched on'), findsOneWidget);
    expect(find.text('Aisyah Rahman'), findsNothing);
  });

  testWidgets('the rail offers memberships only to a company that has it', (
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
              name: 'Gim Sihat Sdn Bhd',
              slug: 'gim',
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

    await tester.pumpWidget(shell(const {'memberships'}));
    await tester.pumpAndSettle();
    expect(find.text('Memberships'), findsOneWidget);

    // A minimart runs a points card and no memberships. That the two
    // are separable is the whole reason 0231 split them.
    await tester.pumpWidget(shell(const {'pos', 'loyalty'}));
    await tester.pumpAndSettle();
    expect(find.text('Memberships'), findsNothing);
  });
}
