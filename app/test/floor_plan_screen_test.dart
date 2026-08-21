import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/core/providers.dart';
import 'package:iakauntan/src/core/theme.dart';
import 'package:iakauntan/src/features/pos/floor_plan_screen.dart';

/// The room.
///
/// Which tables are free is asserted in `supabase/tests/pos_fnb.sql`,
/// against `pos_floor_plan` itself. What is asserted here is what a
/// waiter crossing the room is shown: that a taken table says so
/// without being tapped, that the count at the top matches the tiles
/// under it, and that a room nobody has drawn yet says so rather than
/// rendering as an empty grid somebody has to interpret.
void main() {
  Map<String, dynamic> register({
    String id = 'reg-1',
    String name = 'Tablet',
  }) => {
    'id': id,
    'code': 'T2',
    'name': name,
    'is_active': true,
    'pos_outlets': {
      'id': 'out-1',
      'name': 'The warung',
      'code': 'WARUNG',
      'business_type': 'food_beverage',
    },
  };

  Map<String, dynamic> table({
    required String id,
    required String name,
    String? area = 'Inside',
    int seats = 4,
    String? saleId,
    int? covers,
    num total = 0,
    int? minutes,
    String? parent,
  }) => {
    'table_id': id,
    'table_code': name,
    'table_name': name,
    'area': area,
    'seats': seats,
    'pos_x': null,
    'pos_y': null,
    'shape': 'square',
    'sale_id': saleId,
    'sale_no': saleId == null ? null : 'S-0001',
    'covers': covers,
    'opened_at': null,
    'minutes_seated': minutes,
    'total_amount': '$total',
    'line_count': saleId == null ? null : 2,
    'parent_table_id': parent,
  };

  Widget harness({
    List<Map<String, dynamic>> registers = const [],
    List<Map<String, dynamic>> plan = const [],
  }) => ProviderScope(
    overrides: [
      posRegistersProvider.overrideWith((_) async => registers),
      posFloorPlanProvider.overrideWith((_, __) async => plan),
    ],
    child: MaterialApp(theme: AppTheme.light(), home: const FloorPlanScreen()),
  );

  testWidgets('a company with no register is told what is missing', (
    tester,
  ) async {
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();

    expect(find.text('No tills yet'), findsOneWidget);
  });

  testWidgets('an outlet with no tables says so rather than drawing nothing', (
    tester,
  ) async {
    await tester.pumpWidget(harness(registers: [register()]));
    await tester.pumpAndSettle();

    expect(find.text('No tables yet'), findsOneWidget);
  });

  testWidgets('a free table offers its seats, a taken one its bill', (
    tester,
  ) async {
    await tester.pumpWidget(
      harness(
        registers: [register()],
        plan: [
          table(id: 't1', name: 'T1'),
          table(
            id: 't2',
            name: 'T2',
            saleId: 'sale-1',
            covers: 3,
            total: 47.50,
            minutes: 25,
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Free · 4 seats'), findsOneWidget);
    expect(find.text('3 covers'), findsOneWidget);
    expect(find.text('RM 47.50'), findsOneWidget);
    expect(find.text('25m'), findsOneWidget);
  });

  testWidgets('the count at the top matches the tiles under it', (
    tester,
  ) async {
    await tester.pumpWidget(
      harness(
        registers: [register()],
        plan: [
          table(id: 't1', name: 'T1'),
          table(id: 't2', name: 'T2', saleId: 'sale-1', covers: 2),
          table(id: 't3', name: 'T3', saleId: 'sale-2', covers: 4),
        ],
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('2 of 3 taken'), findsOneWidget);
  });

  testWidgets('an hour is shown as hours, not as ninety-three minutes', (
    tester,
  ) async {
    await tester.pumpWidget(
      harness(
        registers: [register()],
        plan: [
          table(
            id: 't1',
            name: 'T1',
            saleId: 'sale-1',
            covers: 2,
            minutes: 143,
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('2h 23m'), findsOneWidget);
    expect(find.text('143m'), findsNothing);
  });

  testWidgets('areas are headed, so two rooms are two rooms', (tester) async {
    await tester.pumpWidget(
      harness(
        registers: [register()],
        plan: [
          table(id: 't1', name: 'T1'),
          table(id: 't5', name: 'T5', area: 'Outside'),
        ],
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Inside'), findsOneWidget);
    expect(find.text('Outside'), findsOneWidget);
  });

  testWidgets('only a taken table offers to move its party', (tester) async {
    await tester.pumpWidget(
      harness(
        registers: [register()],
        plan: [
          table(id: 't1', name: 'T1'),
          table(id: 't2', name: 'T2', saleId: 'sale-1', covers: 2),
        ],
      ),
    );
    await tester.pumpAndSettle();

    // A free table has no party to move, and an affordance that does
    // nothing is worse than none.
    await tester.tap(find.byIcon(Icons.more_vert).first);
    await tester.pumpAndSettle();
    expect(find.text('Move this party'), findsNothing);
    await tester.tapAt(const Offset(4, 4));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.more_vert).last);
    await tester.pumpAndSettle();
    expect(find.text('Move this party'), findsOneWidget);
  });

  testWidgets('an ordinary table offers to split', (tester) async {
    // Two unrelated parties down one long table is the ordinary case
    // this exists for, and it happens mid-service — so it is on the
    // tile, not buried in a setup screen.
    await tester.pumpWidget(
      harness(registers: [register()], plan: [table(id: 't1', name: 'T1')]),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    expect(find.text('Split this table'), findsOneWidget);
    expect(find.text('Put the table back together'), findsNothing);
  });

  testWidgets('and a half offers to be put back, not split again', (
    tester,
  ) async {
    // `split_pos_table` refuses a half, so offering it here would be
    // offering something the database will turn down.
    await tester.pumpWidget(
      harness(
        registers: [register()],
        plan: [table(id: 't1a', name: 'T1 A', parent: 't1')],
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    expect(find.text('Put the table back together'), findsOneWidget);
    expect(find.text('Split this table'), findsNothing);
  });

  testWidgets('splitting says what the halves will be called', (tester) async {
    // The codes are what goes on the printed cards and what a cashier
    // types, so "2" on its own does not tell anybody what they are
    // about to have.
    await tester.pumpWidget(
      harness(registers: [register()], plan: [table(id: 't1', name: 'T1')]),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Split this table'));
    await tester.pumpAndSettle();

    expect(find.text('Split T1'), findsOneWidget);
    expect(find.text('T1-A   T1-B'), findsOneWidget);

    // Up to three, and the preview keeps up.
    await tester.tap(find.byIcon(Icons.add_circle_outline));
    await tester.pumpAndSettle();
    expect(find.text('T1-A   T1-B   T1-C'), findsOneWidget);
  });

  testWidgets('the cards for the tables can be printed from here', (
    tester,
  ) async {
    // The scan path is only worth having once there is something in
    // the room to scan, and this screen is where somebody setting a
    // dining room up already is.
    await tester.pumpWidget(
      harness(registers: [register()], plan: [table(id: 't1', name: 'T1')]),
    );
    await tester.pumpAndSettle();

    final print = find.widgetWithIcon(IconButton, Icons.qr_code_2);
    expect(print, findsOneWidget);
    expect(tester.widget<IconButton>(print).onPressed, isNotNull);
  });

  testWidgets('and not before a till has been picked', (tester) async {
    // Without a register there is no outlet, and without an outlet
    // there are no tables to make cards for. A button that can only
    // fail is worse than one that is plainly not ready.
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();

    final print = find.widgetWithIcon(IconButton, Icons.qr_code_2);
    expect(tester.widget<IconButton>(print).onPressed, isNull);
  });
}
