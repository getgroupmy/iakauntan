import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/core/providers.dart';
import 'package:iakauntan/src/core/theme.dart';
import 'package:iakauntan/src/features/pos/stations_screen.dart';

/// The counters, and what goes to each.
///
/// The rules are asserted in `supabase/tests/pos_fnb.sql`, against the
/// functions that apply them. What is asserted here is the one thing a
/// screen can get wrong on its own: saying which rule decided a row. A
/// default and a deliberate rule look identical if the screen shows
/// only the destination, and somebody meaning to change one dish
/// changes every drink on the menu instead.
void main() {
  Map<String, dynamic> outlet() => {
    'id': 'out-1',
    'code': 'WARUNG',
    'name': 'Warung Sedap',
    'business_type': 'food_beverage',
    'is_active': true,
  };

  Map<String, dynamic> station(
    String id,
    String code,
    String name, {
    bool isDefault = false,
  }) => {
    'id': id,
    'code': code,
    'name': name,
    'sort_order': 1,
    'is_default': isDefault,
    'is_active': true,
  };

  Map<String, dynamic> routed(
    String name, {
    String? category,
    required String station,
    required String decidedBy,
  }) => {
    'item_id': 'i-$name',
    'item_code': name.toUpperCase(),
    'item_name': name,
    'category_id': category == null ? null : 'cat-$category',
    'category': category,
    'station_id': 'st-1',
    'station': station,
    'decided_by': decidedBy,
  };

  Map<String, dynamic> channel(
    String name, {
    bool isDefault = false,
    bool isActive = true,
    int sortOrder = 1,
  }) => {
    'id': 'ch-$name',
    'channel': name,
    'is_default': isDefault,
    'is_active': isActive,
    'sort_order': sortOrder,
  };

  Widget harness({
    List<Map<String, dynamic>> stations = const [],
    List<Map<String, dynamic>> routing = const [],
    List<Map<String, dynamic>> channels = const [],
    List<Map<String, dynamic>> mix = const [],
  }) => ProviderScope(
    overrides: [
      posOutletsProvider.overrideWith((_) async => [outlet()]),
      posKitchenStationsProvider.overrideWith((_, __) async => stations),
      posStationRoutingProvider.overrideWith((_, __) async => routing),
      posOutletChannelsProvider.overrideWith((_, __) async => channels),
      posChannelMixProvider.overrideWith((_) async => mix),
    ],
    child: MaterialApp(theme: AppTheme.light(), home: const StationsScreen()),
  );

  testWidgets('a shop with no counters is told why it needs one', (
    tester,
  ) async {
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();

    // Not an empty list: a docket has to be routed somewhere, and an
    // outlet with no default counter cannot send an order at all.
    expect(find.textContaining('has to be routed somewhere'), findsOneWidget);
  });

  testWidgets('the default counter says it takes anything unrouted', (
    tester,
  ) async {
    await tester.pumpWidget(
      harness(
        stations: [
          station('st-1', 'DAPUR', 'Dapur', isDefault: true),
          station('st-2', 'BAR', 'Bar minuman'),
        ],
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Dapur'), findsOneWidget);
    expect(find.text('Bar minuman'), findsOneWidget);
    expect(find.textContaining('takes anything unrouted'), findsOneWidget);
  });

  testWidgets('every row says which rule decided it', (tester) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      harness(
        stations: [station('st-1', 'DAPUR', 'Dapur', isDefault: true)],
        routing: [
          routed(
            'Teh tarik',
            category: 'Minuman',
            station: 'Bar minuman',
            decidedBy: 'category',
          ),
          routed(
            'Kopi special',
            category: 'Minuman',
            station: 'Dapur',
            decidedBy: 'item',
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();

    // Grouped by category, which is where the rule that covers most of
    // the menu actually lives.
    expect(find.text('Minuman'), findsOneWidget);
    await tester.tap(find.text('Minuman'));
    await tester.pumpAndSettle();

    // The distinction the whole screen exists to make visible.
    expect(find.text('From its category'), findsOneWidget);
    expect(find.text('Set on this dish'), findsOneWidget);
    expect(find.text('Set the rule for this whole category'), findsOneWidget);
  });

  testWidgets('a dish with no category cannot be given a category rule', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      harness(
        stations: [station('st-1', 'DAPUR', 'Dapur', isDefault: true)],
        routing: [
          routed('Roti canai', station: 'Dapur', decidedBy: 'default'),
        ],
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('No category'), findsOneWidget);
    // There is nothing to inherit from, so offering the rule would be
    // offering something that cannot be set.
    expect(find.textContaining('No category rule possible'), findsOneWidget);

    await tester.tap(find.text('No category'));
    await tester.pumpAndSettle();
    expect(find.text('Set the rule for this whole category'), findsNothing);
    expect(find.text('The outlet default'), findsOneWidget);
  });

  testWidgets('a channel the shop does not take is switched off', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(900, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      harness(
        stations: [station('st-1', 'DAPUR', 'Dapur', isDefault: true)],
        channels: [
          channel('dine_in', isDefault: true),
          channel('takeaway', sortOrder: 2),
          channel('delivery', isActive: false, sortOrder: 3),
        ],
      ),
    );
    await tester.pumpAndSettle();

    // Every channel is listed whether or not the shop takes it, because
    // turning one on is the thing somebody came here to do.
    expect(find.text('Dine-in'), findsOneWidget);
    expect(find.text('Delivery'), findsOneWidget);
    expect(find.text('Mobile app'), findsOneWidget);

    final dineIn = tester.widget<SwitchListTile>(
      find.ancestor(
        of: find.text('Dine-in'),
        matching: find.byType(SwitchListTile),
      ),
    );
    expect(dineIn.value, isTrue);

    final delivery = tester.widget<SwitchListTile>(
      find.ancestor(
        of: find.text('Delivery'),
        matching: find.byType(SwitchListTile),
      ),
    );
    expect(delivery.value, isFalse);

    // The default says what it means where it is, because it is what
    // nearly every sale silently becomes.
    expect(find.text('Default'), findsOneWidget);
    expect(
      find.text('What a sale is unless the till says otherwise'),
      findsOneWidget,
    );
    // And a channel that is on but not the default offers to become it.
    expect(find.text('Make this the default'), findsWidgets);
  });

  testWidgets('the mix is shown beside the switches, not elsewhere', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(900, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      harness(
        stations: [station('st-1', 'DAPUR', 'Dapur', isDefault: true)],
        channels: [channel('dine_in', isDefault: true)],
        mix: [
          {
            'channel': 'dine_in',
            'sales': 42,
            'total': '1680.00',
            'average': '40.00',
            'covers': 96,
          },
        ],
      ),
    );
    await tester.pumpAndSettle();

    // "Is this channel worth keeping on" is the question somebody is
    // holding while they look at the switches, so the answer is on the
    // same screen.
    expect(find.text('RM 1,680.00'), findsOneWidget);
    expect(find.textContaining('42 sales'), findsOneWidget);
    expect(find.textContaining('96 covers'), findsOneWidget);
  });
}
