import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:iakauntan/src/core/providers.dart';
import 'package:iakauntan/src/core/theme.dart';
import 'package:iakauntan/src/data/models.dart';
import 'package:iakauntan/src/features/pos/takings_screen.dart';

/// The day, across every outlet.
///
/// What is asserted here is the thing the screen exists to get right:
/// that the two clocks stay apart. Everything on a row is about the
/// trading day named except the open count, which is about now — and a
/// screen that added them together, or quietly labelled them the same,
/// would be telling an owner something untrue about their own money.
void main() {
  Map<String, dynamic> outlet(
    String name, {
    int bills = 0,
    double gross = 0,
    double cash = 0,
    double nonCash = 0,
    double average = 0,
    int open = 0,
    int voided = 0,
    double voidedValue = 0,
  }) => {
    'outlet_id': name.toLowerCase(),
    'outlet_name': name,
    'bills': bills,
    'gross': '$gross',
    'cash': '$cash',
    'non_cash': '$nonCash',
    'average_bill': '$average',
    'open_bills': open,
    'open_value': '0',
    'voided_bills': voided,
    'voided_value': '$voidedValue',
  };

  Widget screen({
    List<Map<String, dynamic>> board = const [],
    bool pos = true,
  }) => ProviderScope(
    overrides: [
      currentUserProvider.overrideWithValue(null),
      authStateProvider.overrideWith((_) => const Stream<AuthState>.empty()),
      currentOrgProvider.overrideWith(
        (_) async => Organization(
          id: 'o1',
          name: 'Warung Sedap',
          slug: 'warung',
          baseCurrency: 'MYR',
        ),
      ),
      enabledModulesProvider.overrideWith(
        (_) async => pos ? {'pos'} : <String>{},
      ),
      posDayBoardProvider.overrideWith((_, __) async => board),
    ],
    child: MaterialApp(theme: AppTheme.light(), home: const TakingsScreen()),
  );

  Future<void> show(WidgetTester tester, Widget w) async {
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(w);
    await tester.pumpAndSettle();
  }

  testWidgets('every shop is a row, ranked by what it took', (tester) async {
    await show(
      tester,
      screen(
        board: [
          outlet('Bangsar', bills: 40, gross: 1200, cash: 800, nonCash: 400,
              average: 30),
          outlet('Cheras', bills: 12, gross: 300, cash: 300, average: 25),
        ],
      ),
    );

    expect(find.text('Bangsar'), findsOneWidget);
    expect(find.text('Cheras'), findsOneWidget);
    // The company total, which is the number the screen exists for.
    expect(find.text('RM 1,500.00'), findsOneWidget);
    expect(find.text('52 bills'), findsOneWidget);
  });

  testWidgets('a shop that sold nothing is still on the board', (
    tester,
  ) async {
    await show(
      tester,
      screen(
        board: [
          outlet('Bangsar', bills: 40, gross: 1200, cash: 1200, average: 30),
          outlet('Cheras'),
        ],
      ),
    );

    // Its absence would read as "no problem" when it is the problem.
    expect(find.text('Cheras'), findsOneWidget);
    expect(find.textContaining('0 bills'), findsWidgets);
  });

  testWidgets('bills open now are counted apart from the day', (tester) async {
    await show(
      tester,
      screen(
        board: [
          outlet('Bangsar', bills: 40, gross: 1200, cash: 1200, average: 30,
              open: 3),
        ],
      ),
    );

    // Named as now, not folded into the day's total. The takings show
    // twice — once as the company total, once on the shop's own row —
    // and neither of them has three added to it.
    expect(find.text('Open right now'), findsOneWidget);
    expect(find.text('3'), findsOneWidget);
    expect(find.text('RM 1,200.00'), findsNWidgets(2));
    expect(find.textContaining('3 still open'), findsOneWidget);
  });

  testWidgets('what was written off is said on the row', (tester) async {
    await show(
      tester,
      screen(
        board: [
          outlet('Bangsar', bills: 40, gross: 1200, cash: 1200, average: 30,
              voided: 2, voidedValue: 86),
        ],
      ),
    );

    expect(find.textContaining('2 written off'), findsOneWidget);
    expect(find.textContaining('RM 86.00'), findsOneWidget);
  });

  testWidgets('a company with no till is told so rather than shown noughts', (
    tester,
  ) async {
    await show(tester, screen(pos: false));
    expect(find.text('The till is not switched on'), findsOneWidget);
  });
}
