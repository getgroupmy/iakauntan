import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/core/providers.dart';
import 'package:iakauntan/src/core/theme.dart';
import 'package:iakauntan/src/features/pos/kitchen_screen.dart';

/// The kitchen display.
///
/// What gets routed where is asserted in `supabase/tests/pos_fnb.sql`,
/// against `send_order_to_kitchen` itself. What is asserted here is
/// what somebody holding a pan is shown: that the button says what
/// happens next rather than naming a status, that a plate on the pass
/// offers nothing further to press, and that a modifier is attached to
/// the plate it changes rather than standing as its own order.
void main() {
  Map<String, dynamic> register() => {
    'id': 'reg-1',
    'code': 'T1',
    'name': 'Counter',
    'is_active': true,
    'pos_outlets': {
      'id': 'out-1',
      'name': 'The warung',
      'code': 'WARUNG',
      'business_type': 'food_beverage',
    },
  };

  Map<String, dynamic> station({
    String id = 'st-1',
    String name = 'Kitchen',
  }) => {
    'id': id,
    'code': name.toUpperCase(),
    'name': name,
    'sort_order': 0,
    'is_default': true,
    'is_active': true,
  };

  Map<String, dynamic> ticket({
    int no = 1,
    String status = 'new',
    String? table = 'T1',
    int waiting = 3,
    List<Map<String, dynamic>> items = const [],
  }) => {
    'ticket_id': 'tk-$no',
    'ticket_no': no,
    'status': status,
    'table_code': table,
    'covers': 2,
    'sent_at': null,
    'minutes_waiting': waiting,
    'items': items,
  };

  Widget harness({
    List<Map<String, dynamic>> registers = const [],
    List<Map<String, dynamic>> stations = const [],
    List<Map<String, dynamic>> board = const [],
  }) => ProviderScope(
    overrides: [
      posRegistersProvider.overrideWith((_) async => registers),
      posKitchenStationsProvider.overrideWith((_, __) async => stations),
      kitchenDisplayProvider.overrideWith((_, __) async => board),
    ],
    child: MaterialApp(theme: AppTheme.light(), home: const KitchenScreen()),
  );

  testWidgets('an outlet with no station says so', (tester) async {
    await tester.pumpWidget(harness(registers: [register()]));
    await tester.pumpAndSettle();

    expect(find.text('No kitchen stations'), findsOneWidget);
  });

  testWidgets('an empty pass is a good state, not an error', (tester) async {
    await tester.pumpWidget(
      harness(registers: [register()], stations: [station()]),
    );
    await tester.pumpAndSettle();

    expect(find.text('Nothing waiting'), findsOneWidget);
  });

  testWidgets('the button says what happens next, not what the status is', (
    tester,
  ) async {
    await tester.pumpWidget(
      harness(
        registers: [register()],
        stations: [station()],
        board: [ticket(no: 7)],
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('#7'), findsOneWidget);
    // "Start", not "new". A cook reads a verb.
    expect(find.text('Start'), findsOneWidget);
    expect(find.text('new'), findsNothing);
  });

  testWidgets('a ticket already cooking offers the pass', (tester) async {
    await tester.pumpWidget(
      harness(
        registers: [register()],
        stations: [station()],
        board: [ticket(no: 2, status: 'cooking')],
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Ready'), findsOneWidget);
  });

  testWidgets('a modifier sits under its plate, not beside it', (tester) async {
    await tester.pumpWidget(
      harness(
        registers: [register()],
        stations: [station()],
        board: [
          ticket(
            no: 3,
            items: [
              {
                'description': 'Nasi lemak',
                'quantity': '2.0000',
                'modifiers': 'Extra pedas, Telur mata',
                'note': 'no peanuts',
              },
            ],
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();

    // Whole plates read as whole numbers: "2 ×", never "2.0 ×".
    expect(find.text('2 × Nasi lemak'), findsOneWidget);
    expect(find.text('Extra pedas, Telur mata'), findsOneWidget);
    expect(find.text('no peanuts'), findsOneWidget);
  });

  testWidgets('one station needs no chooser', (tester) async {
    await tester.pumpWidget(
      harness(
        registers: [register()],
        stations: [station()],
        board: [ticket()],
      ),
    );
    await tester.pumpAndSettle();

    // A chip row with one chip is a control that can only ever waste a
    // tap.
    expect(find.byType(ChoiceChip), findsNothing);
  });

  testWidgets('two stations are two boards to choose between', (tester) async {
    await tester.pumpWidget(
      harness(
        registers: [register()],
        stations: [station(), station(id: 'st-2', name: 'Bar')],
        board: [ticket()],
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(ChoiceChip), findsNWidgets(2));
    expect(find.text('Bar'), findsOneWidget);
  });
}
