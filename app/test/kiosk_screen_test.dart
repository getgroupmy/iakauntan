import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/core/providers.dart';
import 'package:iakauntan/src/core/theme.dart';
import 'package:iakauntan/src/features/pos/kiosk_screen.dart';

/// The machine by the door.
///
/// The assertion worth having here is the refusal: a screen pointed at
/// a staff till would be a sale with nobody behind it and a drawer that
/// could take cash. `start_kiosk_order` refuses one — this asserts the
/// choice is never offered, so the refusal never has to happen in front
/// of a customer who has nobody to ask why.
void main() {
  Map<String, dynamic> register({
    String id = 'kiosk-1',
    String code = 'K1',
    String name = 'Kiosk by the door',
    bool kiosk = true,
  }) => {
    'id': id,
    'code': code,
    'name': name,
    'is_active': true,
    'is_kiosk': kiosk,
    'pos_outlets': {
      'id': 'out-1',
      'name': 'Warung Sedap',
      'code': 'WARUNG',
      'business_type': 'food_beverage',
    },
  };

  Map<String, dynamic> menuItem(String name, String category, num price) => {
    'item_id': 'i-$name',
    'code': name.toUpperCase(),
    'name': name,
    'unit_price': '$price',
    'uom_code': 'C62',
    'category_id': null,
    'category': category,
    'variant_attributes': <String, dynamic>{},
    'on_hand': '0',
    'tracks_stock': false,
  };

  Widget harness({
    List<Map<String, dynamic>> registers = const [],
    List<Map<String, dynamic>> menu = const [],
  }) => ProviderScope(
    overrides: [
      posRegistersProvider.overrideWith((_) async => registers),
      posMenuProvider.overrideWith((_, __) async => menu),
      posTenderTypesProvider.overrideWith(
        (_) async => const [
          {'id': 't-cash', 'code': 'CASH', 'name': 'Tunai', 'kind': 'cash'},
          {'id': 't-card', 'code': 'CARD', 'name': 'Kad', 'kind': 'card'},
        ],
      ),
    ],
    child: MaterialApp(theme: AppTheme.light(), home: const KioskScreen()),
  );

  testWidgets('a shop with no kiosk register is told so, not shown a till', (
    tester,
  ) async {
    await tester.pumpWidget(harness(registers: [register(kiosk: false)]));
    await tester.pumpAndSettle();

    expect(find.text('No kiosk here'), findsOneWidget);
    // The refusal this screen exists to make unreachable: a staff till
    // is not offered at all.
    expect(find.text('Tap to order'), findsNothing);
  });

  testWidgets('a kiosk waits with nothing on it', (tester) async {
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      harness(
        registers: [register()],
        menu: [menuItem('Nasi', 'Rice', 8.5)],
      ),
    );
    await tester.pumpAndSettle();

    // A kiosk showing the last customer's basket charges the next
    // person for food they did not order, so it starts empty and says
    // only what to do.
    expect(find.text('Tap to order'), findsOneWidget);
    expect(find.text('Your order'), findsNothing);
  });

  testWidgets('tapping anywhere starts, and one category needs no choosing', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      harness(
        registers: [register()],
        menu: [menuItem('Nasi', 'Rice', 8.5), menuItem('Mee', 'Rice', 9)],
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Tap to order'));
    await tester.pumpAndSettle();

    expect(find.text('Your order'), findsOneWidget);
    expect(find.text('Nothing yet'), findsOneWidget);
    // One category is not a choice, so the customer lands on the food.
    expect(find.text('Nasi'), findsOneWidget);
    expect(find.text('Mee'), findsOneWidget);
    expect(find.text('All categories'), findsNothing);
  });

  testWidgets('more than one category is asked before the food', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      harness(
        registers: [register()],
        menu: [menuItem('Nasi', 'Rice', 8.5), menuItem('Teh', 'Drinks', 3)],
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Tap to order'));
    await tester.pumpAndSettle();

    // A wall of tiles is how somebody gives up and joins the queue, so
    // a stranger is asked the smaller question first.
    expect(find.text('Rice'), findsOneWidget);
    expect(find.text('Drinks'), findsOneWidget);
    expect(find.text('Nasi'), findsNothing);

    await tester.tap(find.text('Drinks'));
    await tester.pumpAndSettle();
    expect(find.text('Teh'), findsOneWidget);
    expect(find.text('Nasi'), findsNothing);
    expect(find.text('All categories'), findsOneWidget);
  });

  testWidgets('nothing can be paid for until something is ordered', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      harness(registers: [register()], menu: [menuItem('Nasi', 'Rice', 8.5)]),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Tap to order'));
    await tester.pumpAndSettle();

    final pay = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Pay RM 0.00'),
    );
    expect(pay.onPressed, isNull);
  });
}
