import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:iakauntan/src/core/providers.dart';
import 'package:iakauntan/src/core/theme.dart';
import 'package:iakauntan/src/data/models.dart';
import 'package:iakauntan/src/features/pos/deliveries_screen.dart';
import 'package:iakauntan/src/features/pos/delivery_setup_screen.dart';
import 'package:iakauntan/src/features/pos/delivery_sheet.dart';

/// An address, a fee and a driver.
///
/// The arithmetic — the zone, the fee, what a discount may and may not
/// eat — is asserted in `supabase/tests/pos_delivery.sql`. What is
/// asserted here is what somebody standing at the pass reads off a
/// tablet: whose bag this is, where it is going, how long it has been
/// sat there and whether the money is already in.
void main() {
  Map<String, dynamic> run({
    String id = 'd1',
    String saleNo = 'S-0001',
    String status = 'pending',
    String? recipient = 'Puan Aminah',
    String? driver,
    double fee = 5,
    double total = 41,
    bool paid = false,
    int waiting = 10,
  }) => {
    'id': id,
    'sale_id': 's1',
    'sale_no': saleNo,
    'status': status,
    'recipient': recipient,
    'phone': '012-3456789',
    'address_line1': '12 Jalan Sri 3',
    'address_line2': 'Taman Sri Indah',
    'city': 'Kuala Lumpur',
    'postcode': '58200',
    'state_name': 'Wilayah Persekutuan',
    'notes': null,
    'zone_name': 'Taman Sri',
    'fee': fee,
    'total_amount': total,
    'paid': paid,
    'driver_id': driver == null ? null : 'dr1',
    'driver_name': driver,
    'promised_at': null,
    'waiting_minutes': waiting,
  };

  Widget board({
    List<Map<String, dynamic>> runs = const [],
    bool pos = true,
  }) => ProviderScope(
    overrides: [
      currentUserProvider.overrideWithValue(null),
      authStateProvider.overrideWith((_) => const Stream<AuthState>.empty()),
      currentOrgProvider.overrideWith(
        (_) async => Organization(
          id: 'o1',
          name: 'Warung Sedap',
          slug: 'warung',
          baseCurrency: 'MYR',
        ),
      ),
      enabledModulesProvider.overrideWith(
        (_) async => pos ? {'pos'} : <String>{},
      ),
      posOutletsProvider.overrideWith(
        (_) async => [
          {'id': 'out0', 'name': 'Bangsar'},
        ],
      ),
      posDeliveryBoardProvider.overrideWith((_, __) async => runs),
      posDriversProvider.overrideWith((_) async => const []),
    ],
    child: MaterialApp(
      theme: AppTheme.light(),
      home: const DeliveriesScreen(),
    ),
  );

  Future<void> show(WidgetTester tester, Widget w) async {
    tester.view.physicalSize = const Size(900, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(w);
    await tester.pumpAndSettle();
  }

  // ------------------------------------------------------------------
  // The address, as one line
  // ------------------------------------------------------------------

  test('an address reads in the order an envelope has it', () {
    expect(
      deliveryLine(run()),
      '12 Jalan Sri 3, Taman Sri Indah, 58200 Kuala Lumpur, '
      'Wilayah Persekutuan',
    );
  });

  test('the parts nobody filled in are dropped, not left as commas', () {
    expect(
      deliveryLine({
        'address_line1': '9 Jalan Satu',
        'address_line2': '',
        'city': null,
        'postcode': '58000',
        'state_name': null,
      }),
      '9 Jalan Satu, 58000',
    );
  });

  test('a run reads in the words a shop uses, not the enum', () {
    expect(deliveryStatus('pending'), 'Waiting for a driver');
    expect(deliveryStatus('collected'), 'On the way');
    expect(deliveryStatus('failed'), 'Did not arrive');
  });

  // ------------------------------------------------------------------
  // What a zone charges
  // ------------------------------------------------------------------

  test('a zone says its fee, its minimum and where it stops charging', () {
    expect(
      zoneRule({'fee': 5, 'min_order': 20, 'free_above': 60}),
      'RM 5.00 · over RM 20.00 · free above RM 60.00',
    );
  });

  test('a zone that charges nothing says so in a word', () {
    expect(zoneRule({'fee': 0, 'min_order': 0}), 'Free');
  });

  test('a zone with no postcodes is named as the catch-all', () {
    expect(
      zoneCovers({'postcodes': const []}),
      'Anywhere not named by another zone',
    );
    expect(zoneCovers({'postcodes': const ['58000', '58200']}), '58000, 58200');
  });

  // ------------------------------------------------------------------
  // The board
  // ------------------------------------------------------------------

  testWidgets('an empty board says so rather than showing nothing', (
    tester,
  ) async {
    await show(tester, board());
    expect(find.text('Nothing out'), findsOneWidget);
  });

  testWidgets('a run carries the bill, the name and what it comes to', (
    tester,
  ) async {
    await show(tester, board(runs: [run()]));
    expect(find.text('S-0001 · Puan Aminah · RM 41.00'), findsOneWidget);
    expect(
      find.text(
        '12 Jalan Sri 3, Taman Sri Indah, 58200 Kuala Lumpur, '
        'Wilayah Persekutuan',
      ),
      findsOneWidget,
    );
  });

  testWidgets('an unpaid run says the driver is collecting the money', (
    tester,
  ) async {
    // The one thing a driver has to be told before they go.
    await show(tester, board(runs: [run()]));
    expect(
      find.text('Waiting for a driver · 10 min · to collect on delivery'),
      findsOneWidget,
    );
  });

  testWidgets('a run with a driver on it names them', (tester) async {
    await show(
      tester,
      board(
        runs: [
          run(status: 'collected', driver: 'Hafiz', paid: true, waiting: 22),
        ],
      ),
    );
    expect(find.text('On the way · Hafiz · 22 min · paid'), findsOneWidget);
  });

  testWidgets('a run nobody has picked up is not offered "delivered"', (
    tester,
  ) async {
    // Nothing leaves the shop without a driver on it, and the server
    // refuses it — so the menu does not offer it either.
    await show(tester, board(runs: [run()]));
    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    expect(find.text('Give it to a driver'), findsOneWidget);
    expect(find.text('Delivered'), findsNothing);
    expect(find.text('Did not arrive'), findsOneWidget);
  });

  testWidgets('a run already with a driver can be marked delivered', (
    tester,
  ) async {
    await show(tester, board(runs: [run(status: 'assigned', driver: 'Hafiz')]));
    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    expect(find.text('Delivered'), findsOneWidget);
    expect(find.text('Out of the door'), findsOneWidget);
  });

  testWidgets('a shop without the till is told why the board is empty', (
    tester,
  ) async {
    await show(tester, board(pos: false));
    expect(find.text('The till is not switched on'), findsOneWidget);
  });

  // ------------------------------------------------------------------
  // Taking the address
  // ------------------------------------------------------------------

  testWidgets('the address cannot be saved without a phone number', (
    tester,
  ) async {
    DeliveryAnswer? got;
    await show(
      tester,
      MaterialApp(
        theme: AppTheme.light(),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async =>
                  got = await showDeliverySheet(context),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.widgetWithText(TextField, 'Address'),
      '12 Jalan Sri 3',
    );
    await tester.pumpAndSettle();
    final save = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Save the address'),
    );
    expect(save.onPressed, isNull);

    await tester.enterText(
      find.widgetWithText(TextField, 'Phone'),
      '012-3456789',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save the address'));
    await tester.pumpAndSettle();

    expect(got?.line1, '12 Jalan Sri 3');
    expect(got?.phone, '012-3456789');
    // Never sent from the till: the zone decides it, and a box here
    // would have a cashier typing over the shop's own rule.
    expect(got?.fee, isNull);
  });

  testWidgets('correcting an address starts from the one already taken', (
    tester,
  ) async {
    await show(
      tester,
      MaterialApp(
        theme: AppTheme.light(),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async =>
                  showDeliverySheet(context, existing: run()),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('The address'), findsOneWidget);
    expect(find.text('12 Jalan Sri 3'), findsOneWidget);
    expect(find.text('58200'), findsOneWidget);
  });
}
