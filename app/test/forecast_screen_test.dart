import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/core/providers.dart';
import 'package:iakauntan/src/core/theme.dart';
import 'package:iakauntan/src/features/forecasting/forecast_screen.dart';

/// The replenishment screen.
///
/// What the numbers should be is asserted in
/// `supabase/tests/inventory_forecast.sql`, against the functions that
/// produce them. What is asserted here is what the buyer is shown, and
/// two of those are worth a test on their own:
///
///   * a suggestion that has already been raised as a draft order must
///     not be counted in the button that raises orders, or a second tap
///     buys everything twice as far as the person tapping can tell;
///   * the items the run could not forecast have to be reachable, not
///     merely absent, because an item missing from a replenishment
///     report is one nobody notices they stopped ordering.
void main() {
  Map<String, dynamic> run({
    int suggested = 2,
    int skipped = 1,
    String? warehouseId,
  }) => {
    'id': 'run-1',
    'warehouse_id': warehouseId,
    'as_of_date': '2026-08-18',
    'bucket': 'month',
    'horizon_buckets': 3,
    'history_days': 365,
    'service_level': '0.9500',
    'items_considered': 4,
    'items_forecast': 3,
    'items_skipped': skipped,
    'items_suggested': suggested,
  };

  Map<String, dynamic> suggestion({
    required String code,
    required String name,
    required String state,
    required String suggested,
    String drafted = '0',
    String? supplier,
  }) => {
    'line_id': code,
    'item_id': 'i-$code',
    'item_code': code,
    'item_name': name,
    'uom_code': 'C62',
    'state': state,
    'on_hand': '24.0000',
    'reserved': '0.0000',
    'on_order': '0.0000',
    'available': '24.0000',
    'mean_daily_demand': '0.030324',
    'lead_time_days': '9.00',
    'lead_time_source': 'measured',
    'safety_stock': '1.3247',
    'reorder_point': '1.7492',
    'days_cover': '791.44',
    'stockout_on': null,
    'suggested_qty': suggested,
    'already_drafted': drafted,
    'outstanding': (double.parse(suggested) - double.parse(drafted))
        .clamp(0, double.infinity)
        .toStringAsFixed(4),
    'supplier_id': supplier == null ? null : 's-1',
    'supplier_name': supplier,
  };

  /// The screen opens on the company as a whole, so the fixtures answer
  /// for the null key. `byWarehouse` is for the one test that cares that
  /// the two are different questions.
  Widget harness({
    Map<String, dynamic>? latest,
    List<Map<String, dynamic>> suggestions = const [],
    Map<String?, Map<String, dynamic>?> byWarehouse = const {},
    List<Map<String, dynamic>> warehouses = const [],
  }) => ProviderScope(
    overrides: [
      latestForecastRunProvider.overrideWith(
        (_, id) async => byWarehouse.isEmpty ? latest : byWarehouse[id],
      ),
      forecastSuggestionsProvider.overrideWith((_, __) async => suggestions),
      warehousesProvider.overrideWith((_) async => warehouses),
    ],
    child: MaterialApp(theme: AppTheme.light(), home: const ForecastScreen()),
  );

  testWidgets('before any run, the screen offers to make one', (tester) async {
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();

    expect(find.text('No forecast yet'), findsOneWidget);
    expect(find.text('Run a forecast'), findsOneWidget);
  });

  testWidgets('a drafted suggestion is not counted again', (tester) async {
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      harness(
        latest: run(),
        suggestions: [
          suggestion(
            code: 'ITM-100',
            name: 'Rack Server 2U',
            state: 'order_now',
            suggested: '16.0000',
            supplier: 'Global Components Bhd',
          ),
          suggestion(
            code: 'ITM-110',
            name: 'Network Switch 48-port',
            state: 'order_now',
            suggested: '14.0000',
            drafted: '14.0000',
            supplier: 'Utara Logistik',
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();

    // Both rows are shown — the drafted one stays in the list rather
    // than vanishing, so the item that was dealt with can be found.
    expect(find.textContaining('Rack Server 2U'), findsOneWidget);
    expect(find.textContaining('Network Switch 48-port'), findsOneWidget);
    expect(find.text('order 16'), findsOneWidget);
    expect(find.text('ordered 14'), findsOneWidget);

    // And only the one with something left counts towards the button.
    expect(find.text('Create draft orders (1 item)'), findsOneWidget);
  });

  testWidgets('the skipped items are one tap away', (tester) async {
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      harness(
        latest: run(skipped: 2),
        suggestions: [
          suggestion(
            code: 'ITM-100',
            name: 'Rack Server 2U',
            state: 'order_now',
            suggested: '16.0000',
            supplier: 'Global Components Bhd',
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Skipped (2)'), findsOneWidget);
    expect(find.text('To order (2)'), findsOneWidget);
  });

  testWidgets('with one warehouse there is nothing to pick', (tester) async {
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    // Every small business in the country. A picker with a single entry
    // is a control that can only confirm what is already true.
    await tester.pumpWidget(
      harness(
        latest: run(),
        warehouses: const [
          {'id': 'w1', 'code': 'MAIN', 'name': 'Main'},
        ],
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Whole company'), findsNothing);
  });

  testWidgets('a company-level run is not shown for a branch', (tester) async {
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    // The trap 0205 exists to close. Before the run recorded its
    // warehouse, "the latest run for this company" was the only
    // question that could be asked, so opening a branch showed whatever
    // had been forecast last — real numbers about somewhere else, with
    // nothing saying so.
    await tester.pumpWidget(
      harness(
        byWarehouse: {null: run(), 'w2': null},
        warehouses: const [
          {'id': 'w1', 'code': 'MAIN', 'name': 'Main'},
          {'id': 'w2', 'code': 'BR2', 'name': 'Branch'},
        ],
      ),
    );
    await tester.pumpAndSettle();

    // The company has a run.
    expect(find.text('Whole company'), findsOneWidget);
    expect(find.text('Considered'), findsOneWidget);

    await tester.tap(find.text('Whole company'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('BR2 · Branch').last);
    await tester.pumpAndSettle();

    // The branch does not, and says so rather than borrowing.
    expect(find.text('No forecast yet for this location'), findsOneWidget);
    expect(find.text('Considered'), findsNothing);
  });

  testWidgets('an item with no supplier says so on its row', (tester) async {
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      harness(
        latest: run(suggested: 1),
        suggestions: [
          suggestion(
            code: 'ITM-130',
            name: 'Structured Cabling Kit',
            state: 'order_now',
            suggested: '6.0000',
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();

    // Not a silent omission: the row that cannot become an order says
    // why on its face, because the alternative is an item that quietly
    // never gets bought.
    expect(find.textContaining('No supplier set'), findsOneWidget);
  });
}
