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
    List<Map<String, dynamic>> bills = const [],
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
      posVoidedBillsProvider.overrideWith((_, __) async => bills),
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

  testWidgets('a bill written off with nothing cooked is still listed', (
    tester,
  ) async {
    // The hole 0246 and 0247 left between them, and the one the grant
    // was tightened for. `pos_void_summary` reads line voids, and a
    // bill written off before the kitchen cooked anything writes none —
    // so an order rung up, paid in cash and made to go away would
    // appear nowhere. The summary is deliberately empty here.
    await show(
      tester,
      screen(
        bills: const [
          {
            'sale_id': 's1',
            'sale_no': 'POS-2026-00042',
            'table_code': 'T7',
            'total_amount': 86.00,
            'line_count': 6,
            'cooked_count': 0,
            'reason': 'customer_cancelled',
            'note': null,
            'voided_by': 'u1',
            'voided_name': 'Hafiz Rahman',
          },
        ],
      ),
    );

    expect(find.text('Nothing came off a bill'), findsNothing);
    expect(find.textContaining('POS-2026-00042'), findsOneWidget);
    expect(find.textContaining('86.00'), findsOneWidget);
    // Food lost and an order that never existed are different facts.
    expect(find.textContaining('0 of 6 cooked'), findsOneWidget);
    // And who, because a void nobody is named for tells nobody
    // anything.
    expect(find.textContaining('Hafiz Rahman'), findsOneWidget);
  });

  testWidgets('and what was said, when something else was the reason', (
    tester,
  ) async {
    // "Something else" is made to explain itself; hiding the
    // explanation would waste the one rule that makes the catch-all
    // worth having.
    await show(
      tester,
      screen(
        bills: const [
          {
            'sale_id': 's1',
            'sale_no': 'POS-2026-00043',
            'table_code': null,
            'total_amount': 24.00,
            'line_count': 2,
            'cooked_count': 2,
            'reason': 'other',
            'note': 'they walked out',
            'voided_by': 'u1',
            'voided_name': 'Hafiz Rahman',
          },
        ],
      ),
    );

    expect(find.textContaining('they walked out'), findsOneWidget);
    expect(find.textContaining('2 of 2 cooked'), findsOneWidget);
  });

  testWidgets('the two halves say that they overlap', (tester) async {
    // A bill void writes a line-void row for every line the kitchen
    // cooked, so that food is inside the figure at the top *and* inside
    // the bill total below. Adding the tile to the list overstates the
    // leak, and nothing on the screen said so.
    await show(
      tester,
      screen(
        summary: const [
          {'reason': 'other', 'lines': 2, 'quantity': 3, 'value': 24.00},
        ],
        bills: const [
          {
            'sale_id': 's1',
            'sale_no': 'POS-2026-00043',
            'table_code': 'T7',
            'total_amount': 24.00,
            'line_count': 2,
            'cooked_count': 2,
            'reason': 'other',
            'note': 'they walked out',
            'voided_by': 'u1',
            'voided_name': 'Hafiz Rahman',
          },
        ],
      ),
    );

    expect(
      find.textContaining('already counted above'),
      findsOneWidget,
    );
  });

  testWidgets('and the tile points at what it does not cover', (tester) async {
    // The same confusion the other way round: the tile is lines, so a
    // bill written off before anything was cooked adds nothing to it —
    // which is the case worth catching. Left alone it reads as the
    // whole story.
    await show(
      tester,
      screen(
        summary: const [
          {'reason': 'not_received', 'lines': 3, 'quantity': 3, 'value': 40.00},
        ],
        bills: const [
          {
            'sale_id': 's1',
            'sale_no': 'POS-2026-00044',
            'table_code': null,
            'total_amount': 86.00,
            'line_count': 6,
            'cooked_count': 0,
            'reason': 'customer_cancelled',
            'note': null,
            'voided_by': 'u1',
            'voided_name': 'Faridah Ismail',
          },
        ],
      ),
    );

    expect(find.textContaining('1 bill written off'), findsOneWidget);
  });

  testWidgets('a company with no till is told this is a till control', (
    tester,
  ) async {
    await show(tester, screen(modules: const {'accounting'}));
    expect(find.text('The till is not switched on'), findsOneWidget);
  });
}
