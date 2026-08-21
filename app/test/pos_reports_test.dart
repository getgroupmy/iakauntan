import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:iakauntan/src/core/providers.dart';
import 'package:iakauntan/src/core/theme.dart';
import 'package:iakauntan/src/data/models.dart';
import 'package:iakauntan/src/features/pos/pos_reports_screen.dart';

/// A report somebody builds.
///
/// The allow-list, the arithmetic and the period words are asserted in
/// `supabase/tests/pos_reports.sql`. What is asserted here is the half a
/// shopkeeper touches: what a saved report says it asks, the table it
/// renders, and the spreadsheet it hands over.
void main() {
  Map<String, dynamic> report({
    String id = 'r1',
    String name = 'Takings by outlet',
    String source = 'sales',
    List<String> dims = const ['outlet'],
    List<String> vals = const ['bills', 'gross'],
    String period = 'this_month',
    bool shared = true,
  }) => {
    'id': id,
    'name': name,
    'source': source,
    'dimensions': dims,
    'measures': vals,
    'dim_labels': [for (final d in dims) d == 'outlet' ? 'Outlet' : d],
    'val_labels': [
      for (final v in vals)
        switch (v) {
          'bills' => 'Bills',
          'gross' => 'Takings',
          _ => v,
        },
    ],
    'period': period,
    'is_shared': shared,
    'mine': true,
  };

  Widget screen({
    List<Map<String, dynamic>> reports = const [],
    List<Map<String, dynamic>> rows = const [],
    Map<String, dynamic> headers = const {},
    bool pos = true,
  }) => ProviderScope(
    overrides: [
      currentUserProvider.overrideWithValue(null),
      authStateProvider.overrideWith((_) => const Stream<AuthState>.empty()),
      currentOrgProvider.overrideWith(
        (_) async => Organization(
          id: 'o1',
          name: 'Kedai Laporan',
          slug: 'laporan',
          baseCurrency: 'MYR',
        ),
      ),
      enabledModulesProvider.overrideWith(
        (_) async => pos ? {'pos'} : <String>{},
      ),
      posReportsProvider.overrideWith((_) async => reports),
      posReportRunProvider.overrideWith((_, __) async => rows),
      posReportHeadersProvider.overrideWith((_, __) async => headers),
    ],
    child: MaterialApp(
      theme: AppTheme.light(),
      home: const PosReportsScreen(),
    ),
  );

  Future<void> show(WidgetTester tester, Widget w) async {
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(w);
    await tester.pumpAndSettle();
  }

  // ------------------------------------------------------------------
  // What a saved report says it asks
  // ------------------------------------------------------------------

  test('a report reads back as the question it is', () {
    expect(
      reportSentence(report()),
      'Bills, Takings · by Outlet · this month',
    );
  });

  test('a report with nothing to cut by still reads as a sentence', () {
    expect(
      reportSentence(report(dims: const [], vals: const ['gross'], period: 'today')),
      'Takings · today',
    );
  });

  test('the periods offered are words, never a pair of dates', () {
    // A report saved as the first and last of August is wrong in
    // September, which is why the picker offers no date fields at all.
    expect(posReportPeriods.containsKey('last_month'), isTrue);
    expect(posReportPeriods['last_month'], 'Last month');
    expect(posReportPeriods.keys.any((k) => k.contains('custom')), isFalse);
  });

  // ------------------------------------------------------------------
  // The spreadsheet
  // ------------------------------------------------------------------

  test('a report copies out as comma-separated text', () {
    expect(
      reportCsv(
        ['Outlet', 'Bills', 'Takings'],
        [
          {
            'dims': ['Bangsar'],
            'vals': [3, 81],
          },
          {
            'dims': ['Cheras'],
            'vals': [1, 12],
          },
        ],
      ),
      'Outlet,Bills,Takings\nBangsar,3.00,81.00\nCheras,1.00,12.00',
    );
  });

  test('and quotes anything a spreadsheet would misread', () {
    expect(
      reportCsv(
        ['Item'],
        [
          {
            'dims': ['Nasi lemak, extra sambal'],
            'vals': <num>[],
          },
        ],
      ),
      'Item\n"Nasi lemak, extra sambal"',
    );
  });

  // ------------------------------------------------------------------
  // The screen
  // ------------------------------------------------------------------

  testWidgets('an empty list says what a report is', (tester) async {
    await show(tester, screen());
    expect(find.text('No reports yet'), findsOneWidget);
  });

  testWidgets('a report is listed with what it asks', (tester) async {
    await show(tester, screen(reports: [report()]));
    expect(find.text('Takings by outlet'), findsOneWidget);
    expect(find.text('Bills, Takings · by Outlet · this month'), findsOneWidget);
  });

  testWidgets('a private report is marked as one', (tester) async {
    await show(tester, screen(reports: [report(shared: false)]));
    expect(find.byIcon(Icons.lock_outline), findsOneWidget);
  });

  testWidgets('opening a report shows its rows under the server headings', (
    tester,
  ) async {
    await show(
      tester,
      screen(
        reports: [report()],
        headers: const {
          'name': 'Takings by outlet',
          'dim_labels': ['Outlet'],
          'val_labels': ['Bills', 'Takings'],
          'from_date': '2026-08-01',
          'to_date': '2026-08-22',
        },
        rows: const [
          {
            'dims': ['Bangsar'],
            'vals': [3, 81],
          },
        ],
      ),
    );
    await tester.tap(find.text('Takings by outlet'));
    await tester.pumpAndSettle();

    expect(find.text('Outlet'), findsOneWidget);
    expect(find.text('Takings'), findsOneWidget);
    expect(find.text('Bangsar'), findsOneWidget);
    expect(find.text('81.00'), findsOneWidget);
    expect(find.text('2026-08-01 to 2026-08-22'), findsOneWidget);
  });

  testWidgets('a period with no trading says so rather than showing nothing', (
    tester,
  ) async {
    await show(
      tester,
      screen(
        reports: [report()],
        headers: const {
          'dim_labels': ['Outlet'],
          'val_labels': ['Takings'],
          'from_date': '2026-07-01',
          'to_date': '2026-07-31',
        },
      ),
    );
    await tester.tap(find.text('Takings by outlet'));
    await tester.pumpAndSettle();
    expect(find.text('Nothing in that period'), findsOneWidget);
  });

  testWidgets('a shop without the till is told why', (tester) async {
    await show(tester, screen(pos: false));
    expect(find.text('The till is not switched on'), findsOneWidget);
  });
}
