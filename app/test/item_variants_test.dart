import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:iakauntan/src/core/providers.dart';
import 'package:iakauntan/src/core/theme.dart';
import 'package:iakauntan/src/data/models.dart';
import 'package:iakauntan/src/features/items/item_variants_dialog.dart';

/// The same shirt in six sizes.
///
/// 0211 made a variant an item of its own so that stock, weighted-average
/// cost and reordering all key on the size that actually left the shelf.
/// It built the generator and the axis matrix, granted both to
/// `authenticated`, and nothing in the app ever mentioned
/// `parent_item_id` or `variant_attributes`.
///
/// What is asserted here is the part a shopkeeper sees. The codes and
/// names are not — those are `create_item_variants`' business, and a
/// test that pinned `SHIRT-M-NAVY` here would be pinning a second
/// implementation of the naming rule.
void main() {
  Item shirt({bool trackInventory = true}) => Item(
    id: 'i1',
    code: 'SHIRT',
    name: 'Oxford shirt',
    itemType: 'stock',
    trackInventory: trackInventory,
    unitPrice: 89.90,
  );

  Widget dialog({
    List<Map<String, dynamic>> matrix = const [],
    List<Map<String, dynamic>> variants = const [],
  }) => ProviderScope(
    overrides: [
      currentUserProvider.overrideWithValue(null),
      authStateProvider.overrideWith((_) => const Stream<AuthState>.empty()),
      canWriteProvider.overrideWithValue(true),
      itemVariantMatrixProvider.overrideWith((_, __) async => matrix),
      itemVariantsProvider.overrideWith((_, __) async => variants),
    ],
    child: MaterialApp(
      theme: AppTheme.light(),
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () => showItemVariants(context, shirt()),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );

  Future<void> open(WidgetTester tester, Widget widget) async {
    tester.view.physicalSize = const Size(1200, 1800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(widget);
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('an item nobody has split says it is still one item', (
    tester,
  ) async {
    await open(tester, dialog());

    expect(find.text('Oxford shirt · variants'), findsOneWidget);
    expect(
      find.textContaining('still a single item'),
      findsOneWidget,
    );
    // No axes to report, so nothing claims there are.
    expect(find.text('Already split by'), findsNothing);
  });

  testWidgets('the axes it was split along are read back, not stored twice', (
    tester,
  ) async {
    // `item_variant_matrix` derives these from the children that exist.
    // The dialog shows what came back rather than what was typed, which
    // is the whole reason the axes are not a table.
    await open(
      tester,
      dialog(
        matrix: const [
          {'axis': 'Colour', 'axis_values': ['Navy', 'White']},
          {'axis': 'Size', 'axis_values': ['L', 'M', 'S']},
        ],
        variants: const [
          {
            'id': 'v1',
            'code': 'SHIRT-M-NAVY',
            'name': 'Oxford shirt / M / Navy',
            'variant_attributes': {'Size': 'M', 'Colour': 'Navy'},
            'quantity_on_hand': 4,
            'unit_price': 89.90,
            'is_active': true,
          },
        ],
      ),
    );

    expect(find.text('Already split by'), findsOneWidget);
    expect(find.textContaining('Colour: Navy, White'), findsOneWidget);
    expect(find.textContaining('Size: L, M, S'), findsOneWidget);
    expect(find.text('Oxford shirt / M / Navy'), findsOneWidget);
    expect(find.textContaining('still a single item'), findsNothing);
  });

  testWidgets('a variant shows what is on hand against it, not the style', (
    tester,
  ) async {
    // The reason a variant is an item at all: stock is counted against
    // the size that left the shelf.
    await open(
      tester,
      dialog(
        variants: const [
          {
            'id': 'v1',
            'code': 'SHIRT-S-NAVY',
            'name': 'Oxford shirt / S / Navy',
            'variant_attributes': {'Size': 'S', 'Colour': 'Navy'},
            'quantity_on_hand': 12,
            'unit_price': 89.90,
            'is_active': true,
          },
          {
            'id': 'v2',
            'code': 'SHIRT-M-NAVY',
            'name': 'Oxford shirt / M / Navy',
            'variant_attributes': {'Size': 'M', 'Colour': 'Navy'},
            'quantity_on_hand': 0,
            'unit_price': 89.90,
            'is_active': true,
          },
        ],
      ),
    );

    expect(find.textContaining('SHIRT-S-NAVY · 12'), findsOneWidget);
    expect(find.textContaining('SHIRT-M-NAVY · 0'), findsOneWidget);
  });

  testWidgets('it will not generate from nothing', (tester) async {
    // The one refusal worth making on the client: with no axis typed
    // there is nothing to ask the server for, and the message names the
    // shape it wants rather than saying the request was invalid.
    await open(tester, dialog());
    await tester.tap(find.text('Make variants'));
    // pump rather than pumpAndSettle: a SnackBar sits for four seconds
    // on a timer once its entrance animation is done, and settling is
    // about animations rather than timers.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(
      find.textContaining('Give at least one axis'),
      findsOneWidget,
    );
  });
}
