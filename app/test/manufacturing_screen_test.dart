import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:iakauntan/src/core/providers.dart';
import 'package:iakauntan/src/core/theme.dart';
import 'package:iakauntan/src/features/manufacturing/manufacturing_screen.dart';

/// Manufacturing orders: what to make, and what was made.
///
/// Two things live only in this widget.
///
/// AN ORDER THAT HAS BEEN POSTED REPORTS SOMETHING ELSE. Before
/// posting, the line says how many are TO BE made -- it is an
/// instruction. After, it says how many WERE made against how many were
/// ordered, which is a different fact and often a different number.
/// Show the wrong one and a short run reads as a complete one.
///
/// AND THE COST IS TWO TERMS ADDED. Components plus conversion is what
/// the finished goods go on the shelf at, so it is the figure the
/// balance sheet carries. Drop either term and every manufactured item
/// is understated, quietly, on a line that still looks like a cost.
void main() {
  Map<String, dynamic> order({
    String id = 'mo1',
    String orderNo = 'MO-0001',
    String itemCode = 'CHAIR-01',
    String itemName = 'Office Chair',
    num quantity = 100,
    num quantityDone = 0,
    String status = 'confirmed',
    String? postedAt,
    num componentCost = 0,
    num conversionCost = 0,
  }) => {
    'id': id,
    'order_no': orderNo,
    'items': {'code': itemCode, 'name': itemName},
    'quantity': quantity,
    'quantity_done': quantityDone,
    'status': status,
    'posted_at': postedAt,
    'component_cost': componentCost,
    'conversion_cost': conversionCost,
  };

  late GoRouter router;

  Widget wrap({
    List<Map<String, dynamic>> open = const [],
    List<Map<String, dynamic>> all = const [],
    String role = 'owner',
  }) {
    router = GoRouter(
      initialLocation: '/manufacturing',
      routes: [
        GoRoute(
          path: '/manufacturing',
          builder: (_, __) => const ManufacturingScreen(),
        ),
        GoRoute(
          path: '/manufacturing/:id',
          builder: (_, __) => const Scaffold(body: Text('one order')),
        ),
      ],
    );
    return ProviderScope(
      overrides: [
        manufacturingOrdersProvider(true).overrideWith((ref) async => open),
        manufacturingOrdersProvider(false).overrideWith((ref) async => all),
        bomsProvider.overrideWith((ref) async => const []),
        workCentresProvider.overrideWith((ref) async => const []),
        memberRoleProvider.overrideWith((ref) async => role),
      ],
      child: MaterialApp.router(
        theme: AppTheme.light(),
        routerConfig: router,
      ),
    );
  }

  Future<void> show(
    WidgetTester tester, {
    List<Map<String, dynamic>> open = const [],
    List<Map<String, dynamic>> all = const [],
    String role = 'owner',
  }) async {
    await tester.pumpWidget(wrap(open: open, all: all, role: role));
    await tester.pumpAndSettle();
  }

  group('an order before it is posted', () {
    testWidgets('says how many are to be made', (tester) async {
      await show(tester, open: [
        order(quantity: 100, quantityDone: 0, postedAt: null),
      ]);

      expect(find.text('Office Chair  ·  100 to make'), findsOneWidget);
      // Not "0 of 100 made", which reads as a run that produced nothing
      // rather than one that has not started.
      expect(find.textContaining('made'), findsNothing);
    });

    testWidgets('and carries no cost, because nothing has been consumed',
        (tester) async {
      // The components are still on the shelf. A cost here would be an
      // estimate presented as a fact.
      await show(tester, open: [
        order(postedAt: null, componentCost: 4000, conversionCost: 500),
      ]);

      expect(find.textContaining('cost'), findsNothing);
    });
  });

  group('an order that has been posted', () {
    testWidgets('says what was made against what was ordered',
        (tester) async {
      // 96 of 100: a short run, which is the ordinary case and the
      // reason both numbers are on the line.
      await show(tester, open: [
        order(
          quantity: 100,
          quantityDone: 96,
          postedAt: '2026-09-14T10:00:00Z',
          status: 'posted',
        ),
      ]);

      // The whole subtitle. A posted order ALWAYS carries a cost
      // clause, even at nought, which is why this fixture reads
      // "cost RM 0.00" -- and why the cost tests below set real
      // figures.
      expect(
        find.text('Office Chair  ·  96 of 100 made  ·  cost RM 0.00'),
        findsOneWidget,
      );
      // Exact, not a negative `textContaining('to make')`: the filter
      // above the list is labelled "Still to make", so that assertion
      // matches the chip and asks nothing about the row.
      expect(find.textContaining('100 to make'), findsNothing);
    });

    testWidgets('and its cost is components plus conversion', (tester) async {
      // 4,000 of parts and 500 of labour and machine time is what the
      // finished chairs go on the shelf at. Either term alone is a
      // figure that still looks like a cost.
      await show(tester, open: [
        order(
          postedAt: '2026-09-14T10:00:00Z',
          componentCost: 4000,
          conversionCost: 500,
        ),
      ]);

      expect(find.textContaining('cost RM 4,500.00'), findsOneWidget);
      expect(find.textContaining('RM 4,000.00'), findsNothing);
      expect(find.textContaining('RM 500.00'), findsNothing);
    });

    testWidgets('a run with no conversion cost is still the sum',
        (tester) async {
      // The control that stops the sum being read from one column: a
      // company that does not cost its labour has conversion at nought,
      // and that is the case where "component only" and "the sum" agree.
      // Asserted so the case above cannot be the only evidence.
      await show(tester, open: [
        order(
          postedAt: '2026-09-14T10:00:00Z',
          componentCost: 4000,
          conversionCost: 0,
        ),
      ]);

      expect(find.textContaining('cost RM 4,000.00'), findsOneWidget);
    });
  });

  group('what the row carries', () {
    testWidgets('the order number, the item code and the name',
        (tester) async {
      await show(tester, open: [
        order(orderNo: 'MO-0042', itemCode: 'CHAIR-01',
            itemName: 'Office Chair'),
      ]);

      expect(find.text('MO-0042  ·  CHAIR-01'), findsOneWidget);
      expect(find.textContaining('Office Chair'), findsOneWidget);
    });

    testWidgets('an item with no name leaves no dangling separator',
        (tester) async {
      await show(tester, open: [
        {...order(quantity: 20), 'items': const <String, dynamic>{}},
      ]);

      // Exact. Dropping the `.where(isNotEmpty)` filter puts a LEADING
      // separator in front of the line -- "  ·  20 to make" -- not the
      // doubled one in the middle that a `textContaining('·  ·')` check
      // looks for, so that assertion let the mutant through.
      expect(find.text('20 to make'), findsOneWidget);
    });

    testWidgets('and opens the order it belongs to', (tester) async {
      await show(tester, open: [order(id: 'abc', orderNo: 'MO-0042')]);

      await tester.tap(find.byKey(const ValueKey('mo-MO-0042')));
      await tester.pumpAndSettle();

      // Asserted on what is on screen rather than on `where()`. The row
      // uses `context.push`, and an imperative push does not move
      // `routerDelegate.currentConfiguration.uri` the way `go` does --
      // so the location assertion reads '/manufacturing' on a screen
      // that has correctly navigated, and would equally read it on one
      // that had not.
      expect(find.text('one order'), findsOneWidget);
      expect(find.byKey(const ValueKey('mo-MO-0042')), findsNothing);
    });
  });

  group('the two empty states are not the same', () {
    testWidgets('nothing in progress is not the same as nothing ever',
        (tester) async {
      // A company that has finished everything it ordered must not be
      // told it has no orders at all: the first is a quiet week, the
      // second reads as the feature never having been used.
      await show(tester, open: const [], all: [
        order(postedAt: '2026-09-14T10:00:00Z', status: 'posted'),
      ]);

      expect(find.text('Nothing on the line'), findsOneWidget);
      expect(find.text('No manufacturing orders yet'), findsNothing);
    });

    testWidgets('and a company that has made nothing is told that',
        (tester) async {
      await show(tester, open: const [], all: const []);

      await tester.tap(find.text('Everything'));
      await tester.pumpAndSettle();

      expect(find.text('No manufacturing orders yet'), findsOneWidget);
      expect(find.text('Nothing on the line'), findsNothing);
      // And both states explain what an order does, since somebody
      // seeing either has not used the feature.
      expect(
        find.textContaining('Confirming it works out the parts'),
        findsOneWidget,
      );
    });
  });
}
