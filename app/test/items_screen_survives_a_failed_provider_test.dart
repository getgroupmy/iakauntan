import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/core/providers.dart';
import 'package:iakauntan/src/core/theme.dart';
import 'package:iakauntan/src/data/models.dart';
import 'package:iakauntan/src/features/items/items_screen.dart';

/// The Items screen, with the module list in an error state.
///
/// `enabledModulesProvider` decides which buttons are in the app bar —
/// prices, packs, a stall's menu. Nothing about the items themselves.
/// It was read as `ref.watch(enabledModulesProvider).value ?? const {}`,
/// and `AsyncError.value` THROWS, so the `??` never ran on a failure:
/// a module list that did not load took the whole screen down rather
/// than leaving two buttons off the bar.
///
/// That is the shape of every remaining site on this ratchet, and it is
/// worth one test rather than an argument: the fallback beside each one
/// is always "offer less", and "offer less" is never a reason to show
/// nobody their stock.
void main() {
  Item item({String id = 'i1', String code = 'WIDGET-1'}) => Item(
        id: id,
        code: code,
        name: 'Widget',
        itemType: 'stock',
        unitPrice: 20,
        quantityOnHand: 120,
        trackInventory: true,
      );

  Future<T> fails<T>() => Future<T>.error(StateError('the network went'));

  Widget harness({
    required bool modulesFail,
    List<Item> items = const [],
  }) =>
      ProviderScope(
        overrides: [
          repoProvider.overrideWithValue(null),
          canWriteProvider.overrideWithValue(true),
          itemsProvider.overrideWith((ref, search) async => items),
          enabledModulesProvider.overrideWith(
            (_) => modulesFail
                ? fails<Set<String>>()
                : Future.value(const <String>{}),
          ),
        ],
        child: MaterialApp(theme: AppTheme.light(), home: const ItemsScreen()),
      );

  Future<void> show(WidgetTester tester, Widget w) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1280, 900);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(w);
    await tester.pumpAndSettle();
  }

  testWidgets('a module list that failed still shows the items', (
    tester,
  ) async {
    await show(tester, harness(modulesFail: true, items: [item()]));

    expect(
      tester.takeException(),
      isNull,
      reason: 'the screen threw out of build over the app bar',
    );
    // The point of the screen. A shop looking up a price does not care
    // which modules are switched on.
    expect(find.text('Widget'), findsOneWidget);
  });

  testWidgets('and the control: it shows them when nothing failed', (
    tester,
  ) async {
    // Without this, a harness that never drew the screen at all would
    // pass the assertion above.
    await show(tester, harness(modulesFail: false, items: [item()]));

    expect(tester.takeException(), isNull);
    expect(find.text('Widget'), findsOneWidget);
  });

  testWidgets('an empty shop is still an empty shop, not a crash', (
    tester,
  ) async {
    await show(tester, harness(modulesFail: true));

    expect(tester.takeException(), isNull);
    expect(find.byType(ItemsScreen), findsOneWidget);
  });
}
