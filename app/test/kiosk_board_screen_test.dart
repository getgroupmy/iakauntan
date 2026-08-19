import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/core/providers.dart';
import 'package:iakauntan/src/core/theme.dart';
import 'package:iakauntan/src/features/pos/kiosk_board_screen.dart';

/// The collection board.
///
/// Which orders are on it is asserted in `supabase/tests/pos_kiosk.sql`,
/// against `kiosk_order_board`. What is asserted here is what a
/// customer holding a tray sees: their number, on one of two sides,
/// and nothing else to read or press.
void main() {
  Map<String, dynamic> register() => {
    'id': 'reg-1',
    'code': 'K1',
    'name': 'Kiosk by the door',
    'is_active': true,
    'pos_outlets': {
      'id': 'out-1',
      'name': 'The warung',
      'code': 'WARUNG',
      'business_type': 'kiosk',
    },
  };

  Map<String, dynamic> order(int no, String state) => {
    'order_no': no,
    'state': state,
    'placed_at': null,
    'minutes': 2,
  };

  Widget harness({
    List<Map<String, dynamic>> registers = const [],
    List<Map<String, dynamic>> board = const [],
  }) => ProviderScope(
    overrides: [
      posRegistersProvider.overrideWith((_) async => registers),
      kioskOrderBoardProvider.overrideWith((_, __) async => board),
    ],
    child: MaterialApp(
      theme: AppTheme.light(),
      home: const KioskBoardScreen(),
    ),
  );

  testWidgets('an empty board says everything has been collected', (
    tester,
  ) async {
    await tester.pumpWidget(harness(registers: [register()]));
    await tester.pumpAndSettle();

    expect(find.text('Nothing waiting'), findsOneWidget);
  });

  testWidgets('a number appears on the side its order is actually on', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      harness(
        registers: [register()],
        board: [order(41, 'making'), order(42, 'ready')],
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Preparing'), findsOneWidget);
    expect(find.text('Ready'), findsOneWidget);
    expect(find.text('41'), findsOneWidget);
    expect(find.text('42'), findsOneWidget);
  });

  testWidgets('there is nothing on it for a customer to press', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      harness(registers: [register()], board: [order(7, 'ready')]),
    );
    await tester.pumpAndSettle();

    // A board on a wall. The only control on the screen is the register
    // picker in the bar, and that is not offered for a single till.
    expect(find.byType(ElevatedButton), findsNothing);
    expect(find.byType(FilledButton), findsNothing);
    expect(find.byType(TextButton), findsNothing);
    expect(find.byType(InkWell), findsNothing);
  });
}
