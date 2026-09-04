import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iakauntan/src/data/models.dart';
import 'package:iakauntan/src/features/items/items_screen.dart';

/// What a row of the item list offers, and how it fits on a phone.
///
/// Reported from a phone: the subtitle "ITM-130 · Stock · 29 SET on
/// hand" was rendering ONE CHARACTER PER LINE, a tall column of single
/// letters. `ListTile` gives its `trailing` the width it asks for and
/// leaves the title and subtitle whatever is left — and four text
/// buttons plus a price ask for more than a phone has.
void main() {
  Item item({
    String id = 'i1',
    String code = 'ITM-130',
    bool stock = true,
  }) => Item(
    id: id,
    code: code,
    name: 'Network switch, 24 port',
    itemType: stock ? 'stock' : 'service',
    unitPrice: 1450,
    trackInventory: stock,
    quantityOnHand: 29,
    uomCode: 'SET',
  );

  List<String> labels(Item i, {required bool canWrite}) =>
      itemRowActions(i, canWrite: canWrite).map((a) => a.label).toList();

  group('what a row offers', () {
    test('a stock item somebody may edit offers all four', () {
      expect(labels(item(), canWrite: true),
          ['Stock card', 'Prices', 'Variants', 'Packs']);
    });

    test('a service has no shelf, so no card, no variants and no packs', () {
      // A variant and a pack are both about a thing you can hold.
      expect(labels(item(stock: false), canWrite: true), ['Prices']);
    });

    test('somebody who may not edit still gets the stock card', () {
      // It changes nothing, and the person who has to answer for what
      // is on the shelf is often not the person who may edit prices.
      expect(labels(item(), canWrite: false), ['Stock card']);
    });

    test('and a service they may not edit offers nothing at all', () {
      expect(labels(item(stock: false), canWrite: false), isEmpty);
    });

    test('every action carries a key of its own', () {
      // Two rows in one list must not collide, so the id is in the key.
      final a = itemRowActions(item(id: 'i1'), canWrite: true);
      final b = itemRowActions(item(id: 'i2'), canWrite: true);
      expect(a.map((x) => x.key).toSet().intersection(
            b.map((x) => x.key).toSet(),
          ), isEmpty);
    });
  });

  group('how it fits', () {
    Future<void> pump(WidgetTester tester, double width) async {
      tester.view.physicalSize = Size(width, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ListView(children: [
              ListTile(
                title: const Text('Network switch, 24 port'),
                subtitle: const Text('ITM-130 · Stock · 29 SET on hand'),
                trailing: itemRowTrailing(item(), canWrite: true),
              ),
            ]),
          ),
        ),
      );
    }

    testWidgets('on a phone the actions are behind one menu', (tester) async {
      await pump(tester, 400);
      expect(find.text('Stock card'), findsNothing);
      expect(find.text('Variants'), findsNothing);
      expect(find.byKey(const ValueKey('item-actions-i1')), findsOneWidget);
    });

    testWidgets('and the subtitle is not squeezed to a column of letters',
        (tester) async {
      await pump(tester, 400);
      final subtitle = tester.getSize(find.text('ITM-130 · Stock · 29 SET on hand'));
      // The bug rendered it about one character wide and hundreds tall.
      // Anything sane is wider than it is tall.
      expect(subtitle.width, greaterThan(subtitle.height));
      expect(subtitle.width, greaterThan(100));
    });

    testWidgets('opening the menu shows all four', (tester) async {
      await pump(tester, 400);
      await tester.tap(find.byKey(const ValueKey('item-actions-i1')));
      await tester.pumpAndSettle();

      expect(find.text('Stock card'), findsOneWidget);
      expect(find.text('Prices'), findsOneWidget);
      expect(find.text('Variants'), findsOneWidget);
      expect(find.text('Packs'), findsOneWidget);
    });

    testWidgets('on a wide screen they stay as buttons', (tester) async {
      // A menu on a desktop would be hiding four things behind a click
      // for no reason.
      await pump(tester, 1400);
      expect(find.byKey(const ValueKey('item-actions-i1')), findsNothing);
      expect(find.text('Stock card'), findsOneWidget);
      expect(find.text('Packs'), findsOneWidget);
    });
  });
}
