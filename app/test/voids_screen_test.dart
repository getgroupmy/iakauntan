import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:iakauntan/src/core/providers.dart';
import 'package:iakauntan/src/core/theme.dart';
import 'package:iakauntan/src/data/models.dart';
import 'package:iakauntan/src/features/pos/voids_screen.dart';

/// What went off the bills, and why.
///
/// 0225 wrote `pos_void_summary` for "the screen a manager opens when
/// the food cost does not match the takings" and nothing ever opened
/// it. Voids are where a till leaks: a line taken off after the kitchen
/// cooked it is waste, a mistake, or somebody helping themselves, and
/// all three look the same in the day's takings.
///
/// The grouping is the design, so that is what is asserted: one row per
/// reason, with the money against it, rather than a list of incidents
/// that buries the pattern in the evidence.
void main() {
  Widget screen({
    List<Map<String, dynamic>> summary = const [],
    Set<String> modules = const {'pos'},
  }) => ProviderScope(
    overrides: [
      currentUserProvider.overrideWithValue(null),
      authStateProvider.overrideWith((_) => const Stream<AuthState>.empty()),
      currentOrgProvider.overrideWith(
        (_) async => Organization(
          id: 'o1',
          name: 'Warung Pak Din',
          slug: 'warung',
          baseCurrency: 'MYR',
        ),
      ),
      enabledModulesProvider.overrideWith((_) async => modules),
      posVoidSummaryProvider.overrideWith((_, __) async => summary),
    ],
    child: MaterialApp(
      theme: AppTheme.light(),
      home: const VoidsScreen(),
    ),
  );

  Future<void> show(WidgetTester tester, Widget widget) async {
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(widget);
    await tester.pumpAndSettle();
  }

  testWidgets('a quiet week says nothing came off a bill', (tester) async {
    await show(tester, screen());
    expect(find.text('Nothing came off a bill'), findsOneWidget);
  });

  testWidgets('each reason is its own row, with the money against it', (
    tester,
  ) async {
    await show(
      tester,
      screen(
        summary: const [
          {
            'reason': 'not_received',
            'lines': 30,
            'quantity': 34,
            'value': 486.50,
          },
          {'reason': 'wrong_order', 'lines': 4, 'quantity': 4, 'value': 62.00},
        ],
      ),
    );

    // Thirty "not received" in a week is the conversation this exists
    // to start, so the count has to be on the row.
    expect(find.textContaining('30 lines'), findsOneWidget);
    expect(find.textContaining('4 lines'), findsOneWidget);
    expect(find.text('Nothing came off a bill'), findsNothing);
  });

  testWidgets('the total is the sum of the reasons, not one of them', (
    tester,
  ) async {
    // 486.50 + 62.00. A tile showing the largest reason instead of the
    // sum would understate the leak, which is the number a manager came
    // for.
    await show(
      tester,
      screen(
        summary: const [
          {
            'reason': 'not_received',
            'lines': 30,
            'quantity': 34,
            'value': 486.50,
          },
          {'reason': 'wrong_order', 'lines': 4, 'quantity': 4, 'value': 62.00},
        ],
      ),
    );

    expect(find.textContaining('548.50'), findsOneWidget);
    expect(find.textContaining('2 reasons'), findsOneWidget);
  });

  testWidgets('a company with no till is told this is a till control', (
    tester,
  ) async {
    await show(tester, screen(modules: const {'accounting'}));
    expect(find.text('The till is not switched on'), findsOneWidget);
  });
}
