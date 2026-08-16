import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/core/providers.dart';
import 'package:iakauntan/src/core/theme.dart';
import 'package:iakauntan/src/data/models.dart';
import 'package:iakauntan/src/features/assets/asset_schedule_dialog.dart';
import 'package:iakauntan/src/features/assets/assets_screen.dart';

/// The fixed asset note, and the history behind a line of it.
///
/// The arithmetic is asserted in `supabase/tests/depreciation_schedule.sql`,
/// where the note's movements are held against the ledger and against
/// each other. What is asserted here is the screen: that the note casts,
/// that it says so if it ever does not, and that both reports are gated
/// on reading the ledger rather than on writing.
void main() {
  Map<String, dynamic> note(
    String category, {
    double costOpening = 0,
    double additions = 0,
    double disposalsCost = 0,
    double accumOpening = 0,
    double charge = 0,
    double disposalsAccum = 0,
    double? costClosingOverride,
    double? accumClosingOverride,
  }) {
    final costClosing =
        costClosingOverride ?? costOpening + additions - disposalsCost;
    final accumClosing =
        accumClosingOverride ?? accumOpening + charge - disposalsAccum;
    return {
      'category': category,
      'assets': 1,
      'cost_opening': costOpening,
      'additions': additions,
      'disposals_cost': disposalsCost,
      'cost_closing': costClosing,
      'accum_opening': accumOpening,
      'charge': charge,
      'disposals_accum': disposalsAccum,
      'accum_closing': accumClosing,
      'net_book_value': costClosing - accumClosing,
    };
  }

  // The year from supabase/tests/depreciation_schedule.sql: a van bought
  // and sold inside the period, and a lathe still held.
  final year = [
    note(
      'Motor Vehicles',
      additions: 12000,
      disposalsCost: 12000,
      charge: 1200,
      disposalsAccum: 1200,
    ),
    note('Plant', additions: 24000, charge: 5500),
  ];

  final history = [
    {
      'run_date': '2026-03-31',
      'source': 'Depreciation run',
      'charge': 600.0,
      'opening_accumulated': 0.0,
      'closing_accumulated': 600.0,
      'net_book_value': 11400.0,
    },
    {
      'run_date': '2026-06-30',
      'source': 'Disposal',
      'charge': 600.0,
      'opening_accumulated': 600.0,
      'closing_accumulated': 1200.0,
      'net_book_value': 10800.0,
    },
  ];

  final van = FixedAsset(
    id: 'a1',
    assetNo: 'FA-1',
    name: 'Van',
    acquisitionDate: DateTime(2026, 1, 1),
    cost: 12000,
    usefulLifeMonths: 60,
  );

  // -------------------------------------------------------------------
  // The cast
  // -------------------------------------------------------------------
  test('the note totals down every column', () {
    final t = assetScheduleTotals(year);
    expect(t.additions, 36000);
    expect(t.disposalsCost, 12000);
    expect(t.costClosing, 24000);
    expect(t.charge, 6700);
    expect(t.accumClosing, 5500);
    expect(t.netBookValue, 18500);
  });

  test('an empty note totals to nothing rather than throwing', () {
    expect(assetScheduleTotals(const []).costClosing, 0);
  });

  test('a note that reconciles says nothing', () {
    expect(assetScheduleMiscast(year), isNull);
  });

  test('a cost column that does not cross-cast is named', () {
    final broken = [note('Plant', additions: 24000, costClosingOverride: 999)];
    expect(assetScheduleMiscast(broken), contains('Plant'));
  });

  test('and so is an accumulated column', () {
    // This is the shape the bug in 0084 produced: a charge relieved on
    // disposal without ever being recorded, so the movements no longer
    // reach the closing figure.
    final broken = [
      note(
        'Motor Vehicles',
        additions: 12000,
        disposalsCost: 12000,
        charge: 600,
        disposalsAccum: 1200,
        accumClosingOverride: 0,
      ),
    ];
    expect(assetScheduleMiscast(broken), contains('Motor Vehicles'));
    expect(assetScheduleMiscast(broken), contains('do not file it'));
  });

  test('rounding to the sen does not read as a miscast', () {
    final rounded = [
      note(
        'Plant',
        additions: 24000,
        charge: 5500,
        accumClosingOverride: 5500.004,
      ),
    ];
    expect(assetScheduleMiscast(rounded), isNull);
  });

  // -------------------------------------------------------------------
  // The screens
  // -------------------------------------------------------------------
  Widget scheduleHarness(List<Map<String, dynamic>> rows) => ProviderScope(
    overrides: [
      repoProvider.overrideWithValue(null),
      assetMovementsProvider.overrideWith((ref, args) async => rows),
    ],
    child: MaterialApp(
      theme: AppTheme.light(),
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => showAssetSchedule(context),
            child: const Text('Open'),
          ),
        ),
      ),
    ),
  );

  testWidgets('the note lists each category and totals them', (tester) async {
    await tester.pumpWidget(scheduleHarness(year));
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    expect(find.text('Motor Vehicles'), findsOneWidget);
    expect(find.text('Plant'), findsOneWidget);
    expect(find.text('Total'), findsOneWidget);
    // 36,000 of additions across the two categories, on the totals row.
    expect(find.text('36,000.00'), findsOneWidget);
    expect(find.byKey(const ValueKey('schedule-miscast')), findsNothing);
  });

  testWidgets('a note that does not cross-cast says so on the face of it', (
    tester,
  ) async {
    await tester.pumpWidget(
      scheduleHarness([
        note('Plant', additions: 24000, costClosingOverride: 1),
      ]),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('schedule-miscast')), findsOneWidget);
  });

  testWidgets('a period with no assets says that rather than showing nil', (
    tester,
  ) async {
    await tester.pumpWidget(scheduleHarness(const []));
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(find.textContaining('no note to make'), findsOneWidget);
    expect(find.text('Total'), findsNothing);
  });

  testWidgets("one asset's history names the disposal as a disposal", (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          repoProvider.overrideWithValue(null),
          depreciationHistoryProvider.overrideWith((ref, id) async => history),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showDepreciationHistory(context, van),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Depreciation run'), findsOneWidget);
    // The charge the disposal posted, which before 0156 was relieved
    // without ever being recorded as a charge at all.
    expect(find.textContaining('Disposal'), findsOneWidget);
    expect(find.textContaining('net book RM 10,800.00'), findsOneWidget);
  });

  testWidgets('an asset never charged says so', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          repoProvider.overrideWithValue(null),
          depreciationHistoryProvider.overrideWith((ref, id) async => const []),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showDepreciationHistory(context, van),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(find.textContaining('no run has reached it'), findsOneWidget);
  });

  // -------------------------------------------------------------------
  // Getting to them
  // -------------------------------------------------------------------
  Widget assetsHarness({required bool canReadLedger}) => ProviderScope(
    overrides: [
      repoProvider.overrideWithValue(null),
      canWriteProvider.overrideWithValue(true),
      canPostProvider.overrideWithValue(true),
      canReadLedgerProvider.overrideWithValue(canReadLedger),
      fixedAssetsProvider.overrideWith((ref, includeDisposed) async => [van]),
    ],
    child: MaterialApp(theme: AppTheme.light(), home: const AssetsScreen()),
  );

  testWidgets('both are offered to somebody who may read the ledger', (
    tester,
  ) async {
    await tester.pumpWidget(assetsHarness(canReadLedger: true));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('asset-schedule')), findsOneWidget);
    expect(find.byKey(const ValueKey('asset-history-a1')), findsOneWidget);
  });

  testWidgets('and to nobody else, because this is a ledger disclosure', (
    tester,
  ) async {
    // The stock card takes the opposite view on purpose: a storekeeper
    // answers for a shelf without reading the ledger. A fixed asset note
    // is a balance sheet disclosure, so the bar is the ledger's.
    await tester.pumpWidget(assetsHarness(canReadLedger: false));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('asset-schedule')), findsNothing);
    expect(find.byKey(const ValueKey('asset-history-a1')), findsNothing);
    // The register itself is still there — only the disclosure is gated.
    expect(find.textContaining('FA-1'), findsOneWidget);
  });
}
