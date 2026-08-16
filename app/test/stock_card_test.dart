import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/core/providers.dart';
import 'package:iakauntan/src/core/theme.dart';
import 'package:iakauntan/src/data/models.dart';
import 'package:iakauntan/src/features/items/items_screen.dart';
import 'package:iakauntan/src/features/items/stock_card_dialog.dart';

/// The screen that answers "why is this figure what it is".
///
/// The arithmetic is asserted in `supabase/tests/stock_card.sql`, where
/// the computed running balance is held against the one the trigger
/// stores. What is asserted here is the screen: that it shows every
/// movement, that the filters it offers are actually applied, and that
/// when the movements and the item record disagree it says so instead of
/// showing two numbers and leaving somebody to notice.
void main() {
  Map<String, dynamic> movement(
    String no,
    String date,
    String type,
    double qty,
    double balQty,
    double balValue, {
    String warehouse = 'Main Warehouse',
    String? reference,
  }) => {
    'movement_date': date,
    'movement_no': no,
    'movement_type': type,
    'warehouse': warehouse,
    'reference': reference,
    'quantity': qty,
    'unit_cost': 10.0,
    'total_cost': qty * 10,
    'balance_quantity': balQty,
    'balance_value': balValue,
  };

  final broughtForward = {
    'movement_date': '2026-04-01',
    'movement_no': null,
    'movement_type': null,
    'warehouse': null,
    'reference': 'Brought forward',
    'quantity': null,
    'unit_cost': null,
    'total_cost': null,
    'balance_quantity': 120.0,
    'balance_value': 1280.0,
  };

  final card = [
    movement(
      'SM-0001',
      '2026-03-01',
      'opening_balance',
      100,
      100,
      1000,
      reference: 'Brought over from the old books',
    ),
    movement(
      'SM-0002',
      '2026-03-05',
      'purchase_receipt',
      50,
      150,
      1600,
      reference: 'BILL-2026-00001',
    ),
    movement(
      'SM-0003',
      '2026-03-20',
      'sales_delivery',
      -30,
      120,
      1280,
      reference: 'INV-2026-00002',
    ),
  ];

  final shed = [
    movement(
      'SM-0004',
      '2026-04-10',
      'purchase_receipt',
      40,
      40,
      600,
      warehouse: 'Second Warehouse',
      reference: 'BILL-2026-00002',
    ),
  ];

  Item item({double onHand = 120, bool tracked = true}) => Item(
    id: 'i1',
    code: 'CARD-1',
    name: 'Widget',
    itemType: tracked ? 'stock' : 'service',
    unitPrice: 20,
    quantityOnHand: onHand,
    trackInventory: tracked,
  );

  const warehouses = [
    {'id': 'wh-a', 'code': 'MAIN', 'name': 'Main Warehouse'},
    {'id': 'wh-b', 'code': 'WH-B', 'name': 'Second Warehouse'},
  ];

  Widget harness(
    Item subject, {
    List<Map<String, dynamic>> Function(
      ({String itemId, DateTime? from, DateTime? to, String? warehouseId}),
    )?
    rows,
  }) => ProviderScope(
    overrides: [
      repoProvider.overrideWithValue(null),
      warehousesProvider.overrideWith((ref) async => warehouses),
      // Keyed on the arguments, so a filter that is offered but never
      // passed through shows up as the wrong rows rather than as
      // nothing at all.
      stockCardProvider.overrideWith(
        (ref, args) async => (rows ?? (_) => card)(args),
      ),
    ],
    child: MaterialApp(
      theme: AppTheme.light(),
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => showStockCard(context, subject),
            child: const Text('Open'),
          ),
        ),
      ),
    ),
  );

  Future<void> open(WidgetTester tester, Widget widget) async {
    await tester.pumpWidget(widget);
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
  }

  // -------------------------------------------------------------------
  // What the card closes on
  // -------------------------------------------------------------------
  test('an empty card has no closing balance to state', () {
    expect(stockCardClosing(const [], 'C62'), contains('Nothing has moved'));
  });

  test('the closing average is value over quantity', () {
    // 1,280.00 over 120 is 10.666…, which rounds to 10.67 in the money
    // formatter — the average is derived here rather than read off the
    // last movement, whose average_cost_after is its warehouse's.
    final text = stockCardClosing(card, 'C62');
    expect(text, contains('120'));
    expect(text, contains('10.67'));
  });

  test('a card that closes at nil does not divide by it', () {
    final soldOut = [
      ...card,
      movement('SM-0004', '2026-03-25', 'sales_delivery', -120, 0, 0),
    ];
    final text = stockCardClosing(soldOut, 'C62');
    expect(text, contains('Closing'));
    expect(text, isNot(contains('average')));
  });

  // -------------------------------------------------------------------
  // The comparison against the item record
  // -------------------------------------------------------------------
  test('nothing is said when the movements and the item agree', () {
    expect(
      stockCardDisagreement(
        rows: card,
        onHand: 120,
        narrowed: false,
        uom: 'C62',
      ),
      isNull,
    );
  });

  test('a disagreement is named, with both numbers', () {
    final said = stockCardDisagreement(
      rows: card,
      onHand: 117,
      narrowed: false,
      uom: 'C62',
    );
    expect(said, isNotNull);
    expect(said, contains('120'));
    expect(said, contains('117'));
  });

  test('a narrowed card makes no such claim', () {
    // Filtered to one warehouse or one month the two are not comparable,
    // and a warning that fires on every filtered card is a warning
    // nobody reads.
    expect(
      stockCardDisagreement(
        rows: card,
        onHand: 117,
        narrowed: true,
        uom: 'C62',
      ),
      isNull,
    );
  });

  test('an empty card still disagrees with an item that holds stock', () {
    expect(
      stockCardDisagreement(
        rows: const [],
        onHand: 47,
        narrowed: false,
        uom: 'C62',
      ),
      contains('47'),
    );
  });

  // -------------------------------------------------------------------
  // The screen
  // -------------------------------------------------------------------
  testWidgets('every movement is listed with its running balance', (
    tester,
  ) async {
    await open(tester, harness(item()));

    expect(find.textContaining('SM-0001'), findsOneWidget);
    expect(find.textContaining('SM-0002'), findsOneWidget);
    expect(find.textContaining('SM-0003'), findsOneWidget);
    // The reference, which is what makes it an answer rather than a log.
    expect(find.textContaining('INV-2026-00002'), findsOneWidget);
    expect(find.byKey(const ValueKey('stock-card-closing')), findsOneWidget);
  });

  testWidgets('a disagreement with the item record is shown on the card', (
    tester,
  ) async {
    await open(tester, harness(item(onHand: 117)));
    expect(
      find.byKey(const ValueKey('stock-card-disagreement')),
      findsOneWidget,
    );
  });

  testWidgets('and is absent when the two agree', (tester) async {
    await open(tester, harness(item()));
    expect(find.byKey(const ValueKey('stock-card-disagreement')), findsNothing);
  });

  testWidgets('choosing a warehouse asks again for that warehouse', (
    tester,
  ) async {
    await open(
      tester,
      harness(item(), rows: (args) => args.warehouseId == 'wh-b' ? shed : card),
    );
    expect(find.textContaining('SM-0001'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('stock-card-warehouse')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('WH-B · Second Warehouse').last);
    await tester.pumpAndSettle();

    // The narrowed card, not the whole one — which only happens if the
    // chosen warehouse reached the query.
    expect(find.textContaining('SM-0001'), findsNothing);
    expect(find.textContaining('SM-0004'), findsOneWidget);
  });

  testWidgets('narrowing also silences the comparison', (tester) async {
    await open(
      tester,
      harness(
        item(onHand: 117),
        rows: (args) => args.warehouseId == 'wh-b' ? shed : card,
      ),
    );
    expect(
      find.byKey(const ValueKey('stock-card-disagreement')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey('stock-card-warehouse')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('WH-B · Second Warehouse').last);
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('stock-card-disagreement')), findsNothing);
  });

  testWidgets('a brought-forward line reads as one and carries no movement', (
    tester,
  ) async {
    await open(tester, harness(item(), rows: (_) => [broughtForward, ...shed]));
    final opening = find.byKey(const ValueKey('stock-card-brought-forward'));
    expect(opening, findsOneWidget);
    expect(
      find.descendant(of: opening, matching: find.text('Brought forward')),
      findsOneWidget,
    );
    // It carries the balance it opens on and nothing in the in/out
    // column, because it is not a movement.
    expect(
      find.descendant(of: opening, matching: find.text('120')),
      findsOneWidget,
    );
    // And the movement below it is an ordinary row, not another opening.
    expect(find.textContaining('SM-0004'), findsOneWidget);
  });

  testWidgets('a card with no start date has no brought-forward line', (
    tester,
  ) async {
    await open(tester, harness(item()));
    expect(
      find.byKey(const ValueKey('stock-card-brought-forward')),
      findsNothing,
    );
  });

  testWidgets('an item nothing has happened to says so', (tester) async {
    await open(tester, harness(item(onHand: 0), rows: (_) => const []));
    expect(
      find.textContaining('Nothing has moved for this item'),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('stock-card-closing')), findsNothing);
  });

  // -------------------------------------------------------------------
  // Getting to it
  // -------------------------------------------------------------------
  Widget itemsHarness(List<Item> list, {bool canWrite = true}) => ProviderScope(
    overrides: [
      repoProvider.overrideWithValue(null),
      canWriteProvider.overrideWithValue(canWrite),
      itemsProvider.overrideWith((ref, search) async => list),
    ],
    child: MaterialApp(theme: AppTheme.light(), home: const ItemsScreen()),
  );

  testWidgets('a stocked item offers its card', (tester) async {
    await tester.pumpWidget(itemsHarness([item()]));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('stock-card-i1')), findsOneWidget);
  });

  testWidgets('a service does not, because there is nothing to card', (
    tester,
  ) async {
    await tester.pumpWidget(itemsHarness([item(tracked: false)]));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('stock-card-i1')), findsNothing);
  });

  testWidgets('and it is offered to somebody who may not write', (
    tester,
  ) async {
    // The card changes nothing. The person who has to answer for what is
    // on the shelf is often not the person allowed to edit prices, and
    // gating the two together would put the answer out of their reach.
    await tester.pumpWidget(itemsHarness([item()], canWrite: false));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('stock-card-i1')), findsOneWidget);
    expect(find.text('Prices'), findsNothing);
  });
}
