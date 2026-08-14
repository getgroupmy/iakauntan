import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/core/providers.dart';
import 'package:iakauntan/src/core/theme.dart';
import 'package:iakauntan/src/features/manufacturing/order_screen.dart';

/// What a manufacturing order screen tells somebody about money.
///
/// The arithmetic is asserted in `supabase/tests/manufacturing.sql`,
/// where it belongs — the database is what computes it. What is asserted
/// here is the other half: that the figures the database returned are
/// the figures the screen shows, and that the two sentences a person
/// reads before pressing an irreversible button are actually on it.
///
/// A chair is 4 boards at RM 12.00 and 8 screws at RM 0.50, assembled in
/// half an hour at RM 60.00 an hour. Ten of them: RM 520.00 of parts,
/// RM 300.00 of conversion, RM 820.00 in total, RM 82.00 each.
void main() {
  const id = 'mo-1';

  // The screen is a ListView and a ListView does not build what is off
  // screen, so on the default 800px surface the post card — which is
  // below the parts and the steps — simply does not exist to be found.
  // A tall surface is the honest fix: the assertions are about what the
  // screen says, not about how far somebody scrolled.
  setUp(() {
    final view = TestWidgetsFlutterBinding.ensureInitialized()
        .platformDispatcher
        .views
        .first;
    view.physicalSize = const Size(1200, 4000);
    view.devicePixelRatio = 1.0;
  });

  tearDown(() {
    final view = TestWidgetsFlutterBinding.ensureInitialized()
        .platformDispatcher
        .views
        .first;
    view.resetPhysicalSize();
    view.resetDevicePixelRatio();
  });

  Map<String, dynamic> order({
    required String status,
    bool posted = false,
    num quantity = 10,
    num done = 10,
  }) => {
    'id': id,
    'order_no': 'MO-000010',
    'status': status,
    'quantity': quantity,
    'quantity_done': posted ? done : 0,
    'component_cost': posted ? 520 : 0,
    'conversion_cost': posted ? 300 : 0,
    'posted_at': posted ? '2026-08-14T00:00:00Z' : null,
    'items': {'code': 'CHAIR', 'name': 'Kerusi kayu'},
    'warehouses': {'code': 'MAIN', 'name': 'Gudang Utama'},
    'bills_of_materials': {'code': 'BOM-CHAIR', 'name': 'Chair'},
    'mo_components': [
      {
        'id': 'c1',
        'item_id': 'i-board',
        'quantity_required': 40,
        'quantity_issued': posted ? 40 : 0,
        'total_cost': posted ? 480 : 0,
        'items': {'code': 'BOARD', 'name': 'Papan'},
      },
      {
        'id': 'c2',
        'item_id': 'i-screw',
        'quantity_required': 80,
        'quantity_issued': posted ? 80 : 0,
        'total_cost': posted ? 40 : 0,
        'items': {'code': 'SCREW', 'name': 'Skru'},
      },
    ],
    'mo_operations': [
      {
        'id': 'op1',
        'step_no': 1,
        'name': 'Assemble',
        'planned_minutes': 300,
        'actual_minutes': 0,
        'work_centres': {'code': 'ASSY', 'name': 'Assembly'},
      },
    ],
  };

  Widget harness({
    required Map<String, dynamic> mo,
    List<Map<String, dynamic>> shortages = const [],
    bool canPost = true,
  }) => ProviderScope(
    overrides: [
      canPostProvider.overrideWithValue(canPost),
      manufacturingOrderProvider(id).overrideWith((_) async => mo),
      manufacturingShortagesProvider(id).overrideWith((_) async => shortages),
    ],
    child: MaterialApp(
      theme: AppTheme.light(),
      home: const ManufacturingOrderScreen(orderId: id),
    ),
  );

  testWidgets('a posted order shows what it cost, and what each one cost', (
    tester,
  ) async {
    await tester.pumpWidget(harness(mo: order(status: 'done', posted: true)));
    await tester.pumpAndSettle();

    expect(find.text('RM 520.00'), findsOneWidget);
    expect(find.text('RM 300.00'), findsOneWidget);
    expect(find.text('RM 820.00'), findsOneWidget);
    // The number a costing clerk is actually looking for.
    expect(find.text('RM 82.00'), findsOneWidget);

    // Why the labour is not in the profit and loss twice, said where
    // somebody reading the figures will see it.
    expect(find.textContaining('Manufacturing Cost Absorbed'), findsOneWidget);
  });

  testWidgets('a draft offers to confirm and nothing else', (tester) async {
    await tester.pumpWidget(harness(mo: order(status: 'draft')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('mo-confirm')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('mo-post')),
      findsNothing,
      reason:
          'a draft has no components snapshotted, so posting it would '
          'post nothing at all and call the order finished',
    );
  });

  testWidgets('a confirmed order offers to post, and says what that does', (
    tester,
  ) async {
    await tester.pumpWidget(harness(mo: order(status: 'confirmed')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('mo-post')), findsOneWidget);
    expect(find.byKey(const ValueKey('mo-confirm')), findsNothing);
  });

  testWidgets('a short run says it is costed proportionally', (tester) async {
    await tester.pumpWidget(harness(mo: order(status: 'confirmed')));
    await tester.pumpAndSettle();

    // Ten ordered, six off the line.
    await tester.enterText(find.byKey(const ValueKey('mo-done')), '6');
    await tester.pumpAndSettle();

    expect(find.textContaining('A short run'), findsOneWidget);
    expect(find.textContaining('60'), findsWidgets);
  });

  testWidgets('missing parts are flagged before the button, not after', (
    tester,
  ) async {
    await tester.pumpWidget(
      harness(
        mo: order(status: 'confirmed'),
        shortages: [
          {'item_id': 'i-board', 'quantity_short': 30},
          {'item_id': 'i-screw', 'quantity_short': 0},
        ],
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('30 short'), findsOneWidget);
    expect(find.textContaining('take the stock negative'), findsOneWidget);
  });

  testWidgets('and are not still shouted about once the parts have gone', (
    tester,
  ) async {
    await tester.pumpWidget(
      harness(
        mo: order(status: 'done', posted: true),
        shortages: [
          {'item_id': 'i-board', 'quantity_short': 30},
        ],
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('short'), findsNothing);
  });

  testWidgets('somebody who cannot post is not offered the button', (
    tester,
  ) async {
    await tester.pumpWidget(
      harness(mo: order(status: 'confirmed'), canPost: false),
    );
    await tester.pumpAndSettle();

    final post = find.byKey(const ValueKey('mo-post'));
    expect(tester.widget<FilledButton>(post).onPressed, isNull);
  });
}
