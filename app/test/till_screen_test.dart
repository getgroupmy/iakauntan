import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/core/providers.dart';
import 'package:iakauntan/src/core/theme.dart';
import 'package:iakauntan/src/features/pos/till_screen.dart';
import 'package:iakauntan/src/features/pos/void_sheet.dart';

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

  Map<String, dynamic> menuItem(String name, String category, num price) => {
    'item_id': 'i-$name',
    'code': name.toUpperCase(),
    'name': name,
    'unit_price': '$price',
    'uom_code': 'C62',
    'category_id': null,
    'category': category,
    'variant_attributes': <String, dynamic>{},
    'on_hand': '0',
    'tracks_stock': false,
  };

  Map<String, dynamic> openOrder(
    String id, {
    required String saleNo,
    required String total,
    String registerId = 'reg-1',
    String registerName = 'Counter',
    String registerCode = 'T1',
    int lineCount = 0,
    int sentCount = 0,
    String? tableName,
  }) => {
    'sale_id': id,
    'sale_no': saleNo,
    'register_id': registerId,
    'register_code': registerCode,
    'register_name': registerName,
    'is_kiosk': false,
    'order_no': null,
    'table_id': null,
    'table_name': tableName,
    'covers': null,
    'contact_name': null,
    'opened_at': null,
    'minutes': 0,
    'line_count': lineCount,
    'sent_count': sentCount,
    'total': total,
  };

  Widget harness({
    List<Map<String, dynamic>> registers = const [],
    Map<String, dynamic>? openShift,
    List<Map<String, dynamic>> parked = const [],
    List<Map<String, dynamic>>? open,
    List<Map<String, dynamic>> menu = const [],
    Map<String, dynamic>? sale,
    List<Map<String, dynamic>> saleLines = const [],
    List<Map<String, dynamic>> saleMods = const [],
  }) => ProviderScope(
    overrides: [
      posRegistersProvider.overrideWith((_) async => registers),
      currentPosShiftProvider.overrideWith((_, __) async => openShift),
      parkedPosSalesProvider.overrideWith((_, __) async => parked),
      // The shop-wide list. Derived from [parked] by default so a test
      // that only cares about one bill does not have to say the same
      // thing twice; pass [open] when the point of the test is a bill
      // sitting on another till.
      posOpenOrdersProvider.overrideWith(
        (_, __) async =>
            open ??
            [
              for (final s in parked) openOrder(s['id'] as String,
                  saleNo: '${s['sale_no']}', total: '${s['total_amount']}'),
            ],
      ),
      posTenderTypesProvider.overrideWith((_) async => const []),
      posMenuProvider.overrideWith((_, __) async => menu),
      posSaleProvider.overrideWith((_, __) async => sale),
      posSaleLinesProvider.overrideWith((_, __) async => saleLines),
      posSaleLineModifiersProvider.overrideWith((_, __) async => saleMods),
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
    expect(find.text('Open in this shop'), findsOneWidget);
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

  testWidgets('a bill open on another till is listed, and says whose', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      harness(
        registers: [register()],
        openShift: shift(),
        open: [
          openOrder('s-1', saleNo: 'POS-0009', total: '18.00', lineCount: 2),
          openOrder(
            's-2',
            saleNo: 'POS-0010',
            total: '78.00',
            lineCount: 9,
            sentCount: 5,
            registerId: 'reg-2',
            registerName: 'Waiter tablet',
            registerCode: 'W1',
            tableName: '3',
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();

    // Both are in the shop, so both are on the list. That is the whole
    // change: a till used to see only its own.
    expect(find.text('POS-0009'), findsOneWidget);
    expect(find.text('POS-0010'), findsOneWidget);

    // The row says where the other one is, because the next tap on it
    // is going to ask to move it.
    expect(find.textContaining('on Waiter tablet'), findsOneWidget);
    expect(find.textContaining('Table 3'), findsOneWidget);
    expect(find.textContaining('5 with the kitchen'), findsOneWidget);

    // And this till's own bill says nothing about a register at all.
    expect(find.textContaining('on Counter'), findsNothing);
  });

  testWidgets('taking another till\'s bill asks before it moves the money', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      harness(
        registers: [register()],
        openShift: shift(),
        open: [
          openOrder(
            's-2',
            saleNo: 'POS-0010',
            total: '78.00',
            registerId: 'reg-2',
            registerName: 'Waiter tablet',
            registerCode: 'W1',
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('POS-0010'));
    await tester.pumpAndSettle();

    // The question names the consequence rather than asking "are you
    // sure": what changes is which drawer has to account for the bill,
    // and that is the only thing worth telling a cashier.
    expect(find.text('Take this bill?'), findsOneWidget);
    expect(find.textContaining('this drawer'), findsOneWidget);
    expect(find.text('Leave it'), findsOneWidget);

    // Declining leaves the list exactly as it was.
    await tester.tap(find.text('Leave it'));
    await tester.pumpAndSettle();
    expect(find.text('POS-0010'), findsOneWidget);
    expect(find.text('Take payment'), findsNothing);
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

  group('the menu, when nothing has been scanned', () {
    // The pane used to read "Ready — scan an item, or type part of its
    // name". A barcode is a retail assumption: nasi lemak, a haircut
    // and a roti john all have no label, so for three of the five
    // business types that screen offered no way in at all.

    testWidgets('a short menu is shown as items, not as categories', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1400, 1000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        harness(
          registers: [register()],
          openShift: shift(),
          menu: [
            menuItem('Nasi lemak', 'Makanan', 8.50),
            menuItem('Mee goreng', 'Makanan', 9.00),
            menuItem('Teh tarik', 'Minuman', 3.00),
            menuItem('Kopi O', 'Minuman', 2.50),
          ],
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Nasi lemak'), findsOneWidget);
      expect(find.text('Teh tarik'), findsOneWidget);
      // Four things fit on a counter terminal, so making somebody tap
      // a category to reach them would be pure ceremony.
      expect(find.text('Makanan'), findsNothing);
      expect(find.text('Minuman'), findsNothing);
    });

    testWidgets('a menu too long for the screen is shown as categories', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(420, 780);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        harness(
          registers: [register()],
          openShift: shift(),
          menu: [
            for (var i = 0; i < 20; i++) menuItem('Makan $i', 'Makanan', 8),
            for (var i = 0; i < 20; i++) menuItem('Minum $i', 'Minuman', 3),
          ],
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Makanan'), findsOneWidget);
      expect(find.text('Minuman'), findsOneWidget);
      // A door with nothing written on it is a door nobody opens.
      expect(find.text('20 items'), findsNWidgets(2));
      expect(find.text('Makan 0'), findsNothing);
    });

    testWidgets('tapping a category drills into it, and there is a way back', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(420, 780);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        harness(
          registers: [register()],
          openShift: shift(),
          menu: [
            for (var i = 0; i < 20; i++) menuItem('Makan $i', 'Makanan', 8),
            for (var i = 0; i < 20; i++) menuItem('Minum $i', 'Minuman', 3),
          ],
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Minuman'));
      await tester.pumpAndSettle();

      expect(find.text('Minum 0'), findsOneWidget);
      // Nothing from the other category leaks in.
      expect(find.text('Makan 0'), findsNothing);
      // And the heading doubles as the way out.
      expect(find.byIcon(Icons.arrow_back), findsOneWidget);

      await tester.tap(find.byIcon(Icons.arrow_back));
      await tester.pumpAndSettle();
      expect(find.text('20 items'), findsNWidgets(2));
    });

    testWidgets('one category is never turned into a choice', (tester) async {
      tester.view.physicalSize = const Size(420, 780);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        harness(
          registers: [register()],
          openShift: shift(),
          menu: [
            for (var i = 0; i < 40; i++) menuItem('Makan $i', 'Makanan', 8),
          ],
        ),
      );
      await tester.pumpAndSettle();

      // Too long to fit, but there is nothing to choose between, so the
      // items are shown and scrolled rather than hidden behind a tap.
      expect(find.text('Makan 0'), findsOneWidget);
      expect(find.text('40 items'), findsNothing);
    });

    testWidgets('an outlet with nothing sellable says so', (tester) async {
      await tester.pumpWidget(
        harness(registers: [register()], openShift: shift()),
      );
      await tester.pumpAndSettle();

      expect(find.text('Nothing to sell yet'), findsOneWidget);
      // Scanning is still offered, because a shop mid-setup may have
      // barcodes before it has tidied its item list.
      expect(find.text('Scan, or type a code or a name'), findsOneWidget);
    });
  });

  group('the bill on a phone', () {
    // The bill used to take a fixed 42% of the height, which on an
    // ordinary phone was four lines tall and clipped its own contents.
    // A list that cannot show what is in it is worse than a number
    // saying how much there is.
    //
    // `_saleId` is the till's own state rather than a provider, so
    // these resume a parked bill to get one open — which is also how a
    // cashier reaches an existing bill.
    Future<void> openParked(WidgetTester tester, Widget app) async {
      tester.view.physicalSize = const Size(420, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(app);
      await tester.pumpAndSettle();
      await tester.tap(find.text('POS-2026-00001'));
      await tester.pumpAndSettle();
    }

    Map<String, dynamic> parkedSale() => {
      'id': 'sale-1',
      'sale_no': 'POS-2026-00001',
      'total_amount': '21.00',
      'status': 'parked',
    };

    testWidgets('an open bill offers the way back to the others', (
      tester,
    ) async {
      await openParked(
        tester,
        harness(
          registers: [register()],
          openShift: shift(),
          parked: [parkedSale()],
          sale: parkedSale(),
          saleLines: [
            {
              'id': 'l1',
              'line_no': 1,
              'description': 'Teh tarik',
              'quantity': '1',
              'unit_price': '3.00',
              'line_total': '3.00',
            },
          ],
        ),
      );

      // Which bill this is, said on the screen rather than remembered.
      expect(find.text('POS-2026-00001'), findsOneWidget);

      // Without this the till is a one-way street: the only exit from
      // an open bill would be taking money for it, and a waiter called
      // to another table would have to settle the first one to leave.
      await tester.tap(find.text('Leave it open'));
      await tester.pumpAndSettle();

      // Back on the list, with the bill still there — parking writes
      // nothing, because a sale is parked from the moment it opens.
      expect(find.text('Take payment'), findsNothing);
      expect(find.text('POS-2026-00001'), findsOneWidget);
    });

    testWidgets('a phone shows a count and a total, not the lines', (
      tester,
    ) async {
      await openParked(
        tester,
        harness(
          registers: [register()],
          openShift: shift(),
          parked: [parkedSale()],
          sale: parkedSale(),
          saleLines: [
            {
              'id': 'l1',
              'line_no': 1,
              'description': 'Mee goreng mamak',
              'quantity': '1',
              'unit_price': '9.00',
              'line_total': '9.00',
            },
            {
              'id': 'l2',
              'line_no': 2,
              'description': 'Teh tarik',
              'quantity': '4',
              'unit_price': '3.00',
              'line_total': '12.00',
            },
          ],
        ),
      );

      expect(find.text('5 items'), findsOneWidget);
      expect(find.text('RM 21.00'), findsOneWidget);
      // The lines themselves are behind the tap, not squeezed on
      // screen under a menu that needs the room.
      expect(find.text('Mee goreng mamak'), findsNothing);
    });

    testWidgets('tapping the count opens the whole bill', (tester) async {
      await openParked(
        tester,
        harness(
          registers: [register()],
          openShift: shift(),
          parked: [parkedSale()],
          sale: parkedSale(),
          saleLines: [
            {
              'id': 'l1',
              'line_no': 1,
              'description': 'Mee goreng mamak',
              'quantity': '1',
              'unit_price': '9.00',
              'line_total': '9.00',
            },
          ],
          saleMods: [
            {'line_id': 'l1', 'name': 'Biasa', 'price_delta': '0'},
          ],
        ),
      );

      await tester.tap(find.text('1 item'));
      await tester.pumpAndSettle();

      expect(find.text('On the counter'), findsOneWidget);
      expect(find.text('Mee goreng mamak'), findsOneWidget);
      // And the modifier travels with its line into the sheet.
      expect(find.textContaining('Biasa'), findsOneWidget);
    });

    testWidgets('an empty till offers no tap into nothing', (tester) async {
      tester.view.physicalSize = const Size(420, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        harness(registers: [register()], openShift: shift()),
      );
      await tester.pumpAndSettle();

      expect(find.text('Nothing on the counter'), findsOneWidget);
      expect(find.text('On the counter'), findsNothing);
    });

    testWidgets('sending to the kitchen shows the bill first', (tester) async {
      await openParked(
        tester,
        harness(
          registers: [register()],
          openShift: shift(),
          parked: [parkedSale()],
          sale: parkedSale(),
          saleLines: [
            {
              'id': 'l1',
              'line_no': 1,
              'description': 'Mee goreng mamak',
              'quantity': '1',
              'unit_price': '9.00',
              'line_total': '9.00',
            },
          ],
        ),
      );

      await tester.tap(find.text('Send to kitchen'));
      await tester.pumpAndSettle();

      // The bill, and the same words on the button that agrees to it.
      // A cashier who cannot check what is about to be cooked finds out
      // from the customer.
      expect(find.text('On the counter'), findsOneWidget);
      expect(find.text('Mee goreng mamak'), findsOneWidget);
      expect(find.text('Send to kitchen'), findsNWidgets(2));
    });

    testWidgets('taking payment shows the bill first too', (tester) async {
      await openParked(
        tester,
        harness(
          registers: [register()],
          openShift: shift(),
          parked: [parkedSale()],
          sale: parkedSale(),
          saleLines: [
            {
              'id': 'l1',
              'line_no': 1,
              'description': 'Mee goreng mamak',
              'quantity': '1',
              'unit_price': '9.00',
              'line_total': '9.00',
            },
          ],
        ),
      );

      await tester.tap(find.text('Take payment'));
      await tester.pumpAndSettle();

      expect(find.text('On the counter'), findsOneWidget);
      expect(find.text('Take payment'), findsNWidgets(2));
    });

    testWidgets('a counter needs no confirmation, the bill is on screen', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1400, 1000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        harness(
          registers: [register()],
          openShift: shift(),
          parked: [parkedSale()],
          sale: parkedSale(),
          saleLines: [
            {
              'id': 'l1',
              'line_no': 1,
              'description': 'Mee goreng mamak',
              'quantity': '1',
              'unit_price': '9.00',
              'line_total': '9.00',
            },
          ],
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('POS-2026-00001'));
      await tester.pumpAndSettle();

      // Already visible in the panel, so no sheet is opened — a
      // confirmation that repeats what you are looking at is ceremony
      // rather than a check.
      expect(find.text('Mee goreng mamak'), findsOneWidget);
      await tester.tap(find.text('Send to kitchen'));
      await tester.pumpAndSettle();
      expect(find.text('On the counter'), findsNothing);
    });

    testWidgets('an unsent line offers to come off; a sent one does not', (
      tester,
    ) async {
      await openParked(
        tester,
        harness(
          registers: [register()],
          openShift: shift(),
          parked: [parkedSale()],
          sale: parkedSale(),
          saleLines: [
            {
              'id': 'l1',
              'line_no': 1,
              'description': 'Teh tarik',
              'quantity': '1',
              'unit_price': '3.00',
              'line_total': '3.00',
              'sent_to_kitchen_at': null,
            },
            {
              'id': 'l2',
              'line_no': 2,
              'description': 'Mee goreng mamak',
              'quantity': '1',
              'unit_price': '9.00',
              'line_total': '9.00',
              'sent_to_kitchen_at': '2026-08-19T12:00:00Z',
            },
          ],
        ),
      );

      await tester.tap(find.text('2 items'));
      await tester.pumpAndSettle();

      // The one column the rule turns on, readable on the row itself.
      // Two glyphs that appear nowhere else on this screen, so what is
      // asserted is the row and not something behind the sheet.
      expect(find.byIcon(Icons.remove_circle_outline), findsOneWidget);
      expect(find.byIcon(Icons.lock_outline), findsOneWidget);

      // Unsent: taken off with no ceremony.
      await tester.tap(find.text('Teh tarik'));
      await tester.pumpAndSettle();
      expect(find.text('Take off the bill'), findsOneWidget);
      expect(find.text('Not sent yet'), findsOneWidget);
    });

    testWidgets('a sent line asks why before it comes off', (tester) async {
      await openParked(
        tester,
        harness(
          registers: [register()],
          openShift: shift(),
          parked: [parkedSale()],
          sale: parkedSale(),
          saleLines: [
            {
              'id': 'l2',
              'line_no': 1,
              'description': 'Mee goreng mamak',
              'quantity': '1',
              'unit_price': '9.00',
              'line_total': '9.00',
              'sent_to_kitchen_at': '2026-08-19T12:00:00Z',
            },
          ],
        ),
      );

      await tester.tap(find.text('1 item'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Mee goreng mamak'));
      await tester.pumpAndSettle();

      expect(
        find.text('The kitchen has already made this, so it needs a reason.'),
        findsOneWidget,
      );
      expect(find.text('Never came out'), findsOneWidget);

      // Scoped to the sheet: the till behind it has its own filled
      // button ("Take payment"), and a finder that caught both would
      // be asserting whichever came first.
      final confirm = find.descendant(
        of: find.byType(VoidReasonSheet),
        matching: find.byType(FilledButton),
      );

      // Nothing goes until a reason is picked.
      expect(tester.widget<FilledButton>(confirm).onPressed, isNull);

      await tester.tap(find.text('Never came out'));
      await tester.pumpAndSettle();
      expect(tester.widget<FilledButton>(confirm).onPressed, isNotNull);

      // "Something else" then insists on words, the same rule the
      // database applies.
      await tester.tap(find.text('Something else'));
      await tester.pumpAndSettle();
      expect(tester.widget<FilledButton>(confirm).onPressed, isNull);
    });
  });
}
