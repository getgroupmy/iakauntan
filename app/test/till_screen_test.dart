import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/core/providers.dart';
import 'package:iakauntan/src/core/theme.dart';
import 'package:iakauntan/src/features/pos/till_screen.dart';

/// The till.
///
/// What the money comes to is asserted in `supabase/tests/pos.sql`,
/// against the functions that decide it. What is asserted here is what
/// the cashier is shown, and the one that matters most is the refusal:
/// a closed drawer offers a way to open it and nothing else. A till
/// that let somebody sell first would be putting takings somewhere no
/// count could ever reach.
void main() {
  Map<String, dynamic> register({
    String id = 'reg-1',
    String name = 'Counter',
    String outlet = 'The shop',
  }) => {
    'id': id,
    'code': 'T1',
    'name': name,
    'is_active': true,
    'pos_outlets': {
      'id': 'out-1',
      'name': outlet,
      'code': 'SHOP',
      'business_type': 'retail',
    },
  };

  Map<String, dynamic> shift() => {
    'id': 'shift-1',
    'shift_no': 'SH-0001',
    'status': 'open',
    'opening_float': '100.00',
  };

  Widget harness({
    List<Map<String, dynamic>> registers = const [],
    Map<String, dynamic>? openShift,
    List<Map<String, dynamic>> parked = const [],
  }) => ProviderScope(
    overrides: [
      posRegistersProvider.overrideWith((_) async => registers),
      currentPosShiftProvider.overrideWith((_, __) async => openShift),
      parkedPosSalesProvider.overrideWith((_, __) async => parked),
      posTenderTypesProvider.overrideWith((_) async => const []),
    ],
    child: MaterialApp(theme: AppTheme.light(), home: const TillScreen()),
  );

  testWidgets('a company with no register is told what is missing', (
    tester,
  ) async {
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();

    expect(find.text('No tills yet'), findsOneWidget);
  });

  testWidgets('a closed drawer offers only to open one', (tester) async {
    await tester.pumpWidget(harness(registers: [register()]));
    await tester.pumpAndSettle();

    expect(find.text('The drawer is closed'), findsOneWidget);
    expect(find.text('Open the drawer'), findsOneWidget);
    // Nothing to sell with. This is the assertion: the scan box is not
    // merely disabled, it is not there.
    expect(find.text('Scan, or type a code or a name'), findsNothing);
    expect(find.text('Take payment'), findsNothing);
  });

  testWidgets('an open drawer gives a scan box and an empty basket', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      harness(registers: [register()], openShift: shift()),
    );
    await tester.pumpAndSettle();

    expect(find.text('Scan, or type a code or a name'), findsOneWidget);
    expect(find.text('Shift SH-0001'), findsOneWidget);
    expect(find.text('Nothing on the counter'), findsOneWidget);
    expect(find.text('Empty'), findsOneWidget);
  });

  testWidgets('a parked basket is listed rather than left to be remembered', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      harness(
        registers: [register()],
        openShift: shift(),
        parked: [
          {'id': 's-1', 'sale_no': 'POS-0007', 'total_amount': '42.50'},
        ],
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('POS-0007'), findsOneWidget);
    expect(find.text('RM 42.50'), findsOneWidget);
  });

  testWidgets('one till needs no picker', (tester) async {
    await tester.pumpWidget(harness(registers: [register()]));
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.devices_other), findsNothing);
  });

  testWidgets('two tills need one', (tester) async {
    await tester.pumpWidget(
      harness(
        registers: [
          register(),
          register(id: 'reg-2', name: 'Roaming tablet'),
        ],
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.devices_other), findsOneWidget);
  });
}
