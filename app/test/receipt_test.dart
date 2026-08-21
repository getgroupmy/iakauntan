import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:iakauntan/src/core/providers.dart';
import 'package:iakauntan/src/core/theme.dart';
import 'package:iakauntan/src/data/models.dart';
import 'package:iakauntan/src/features/pos/receipt_settings_screen.dart';
import 'package:iakauntan/src/features/pos/receipt_view.dart';

/// What goes on the receipt.
///
/// The paper itself is asserted in `supabase/tests/pos_receipt.sql`,
/// against `pos_receipt_text` — every line fitting the roll, the
/// switches, and the money that no switch can remove. What is asserted
/// here is that the screen shows the shop the real thing and never
/// re-wraps it: a preview that reflows to the width of a phone is a
/// preview of a receipt no printer will produce.
void main() {
  const paper = '''
                  KEDAI RESIT
            12 Jalan Maarof, Bangsar
------------------------------------------------
Sale POS-2026-00001               22/08/26 01:54
------------------------------------------------
2 x Nasi lemak ayam berempah               24.00
------------------------------------------------
TOTAL                                      24.00
------------------------------------------------
Tunai                                      50.00
Change                                     26.00''';

  Widget screen({
    Map<String, dynamic> settings = const {
      'outlet_id': 'out0',
      'outlet_name': 'Bangsar',
      'header': 'KEDAI RESIT',
      'footer': 'Terima kasih',
      'paper_mm': 80,
      'copies': 1,
      'language': 'en',
      'show_item_codes': false,
      'show_cashier': true,
      'show_table': true,
      'show_channel': false,
      'show_tax_summary': true,
      'show_customer': true,
      'show_points': true,
      'show_einvoice_qr': true,
    },
    String? recent = 's1',
  }) => ProviderScope(
    overrides: [
      currentUserProvider.overrideWithValue(null),
      authStateProvider.overrideWith((_) => const Stream<AuthState>.empty()),
      currentOrgProvider.overrideWith(
        (_) async => Organization(
          id: 'o1',
          name: 'Kedai Resit',
          slug: 'resit',
          baseCurrency: 'MYR',
        ),
      ),
      enabledModulesProvider.overrideWith((_) async => {'pos'}),
      posOutletsProvider.overrideWith(
        (_) async => [
          {'id': 'out0', 'name': 'Bangsar'},
        ],
      ),
      posReceiptSettingsProvider.overrideWith((_, __) async => settings),
      posRecentSaleProvider.overrideWith((_, __) async => recent),
      posReceiptTextProvider.overrideWith((_, __) async => paper),
    ],
    child: MaterialApp(
      theme: AppTheme.light(),
      home: const ReceiptSettingsScreen(),
    ),
  );

  Future<void> show(WidgetTester tester, Widget w) async {
    tester.view.physicalSize = const Size(1000, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(w);
    await tester.pumpAndSettle();
  }

  testWidgets('the paper is never re-wrapped by the screen', (tester) async {
    // softWrap false is the whole assertion: the server already wrapped
    // this to the width of the roll, and a second wrap shows a layout
    // that will not come out of the printer.
    await show(
      tester,
      MaterialApp(
        theme: AppTheme.light(),
        home: const Scaffold(body: ReceiptPaper(paper)),
      ),
    );
    final text = tester.widget<SelectableText>(find.byType(SelectableText));
    expect(text.data, paper);
    expect(
      tester
          .widget<SingleChildScrollView>(find.byType(SingleChildScrollView))
          .scrollDirection,
      Axis.horizontal,
    );
  });

  testWidgets('an empty receipt shows a dash rather than nothing', (
    tester,
  ) async {
    await show(
      tester,
      MaterialApp(
        theme: AppTheme.light(),
        home: const Scaffold(body: ReceiptPaper('')),
      ),
    );
    expect(find.text('—'), findsOneWidget);
  });

  testWidgets('the settings screen reads back what the outlet prints', (
    tester,
  ) async {
    await show(tester, screen());
    expect(find.widgetWithText(TextField, 'Top of the receipt'), findsOneWidget);
    expect(find.text('KEDAI RESIT'), findsWidgets);
    // Twice: the field's contents, and the hint on the footer box.
    expect(find.text('Terima kasih'), findsWidgets);
  });

  testWidgets('the paper the shop buys is offered in millimetres', (
    tester,
  ) async {
    await show(tester, screen());
    expect(find.text('58mm'), findsOneWidget);
    expect(find.text('80mm'), findsOneWidget);
  });

  testWidgets('there is no switch for money that changed hands', (
    tester,
  ) async {
    // The rule the migration enforces, asserted where somebody would
    // otherwise be tempted to add one.
    await show(tester, screen());
    expect(find.text('The tax line'), findsOneWidget);
    expect(find.textContaining('Discount'), findsNothing);
    expect(find.textContaining('Delivery'), findsNothing);
    expect(find.textContaining('Promotion'), findsNothing);
    expect(find.textContaining('Total'), findsNothing);
  });

  testWidgets('the preview is the real receipt, not a mock-up', (
    tester,
  ) async {
    await show(tester, screen());
    await tester.scrollUntilVisible(
      find.byType(ReceiptPaper),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    expect(find.byType(ReceiptPaper), findsOneWidget);
  });

  testWidgets('a shop that has sold nothing is told to ring one up', (
    tester,
  ) async {
    await show(tester, screen(recent: null));
    await tester.scrollUntilVisible(
      find.text('Nothing to show yet'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    expect(find.text('Nothing to show yet'), findsOneWidget);
  });

  testWidgets('the receipt sheet offers a copy and a way out', (tester) async {
    await show(
      tester,
      MaterialApp(
        theme: AppTheme.light(),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showReceiptSheet(context, text: paper),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('Receipt'), findsOneWidget);
    expect(find.text('Copy'), findsOneWidget);
    expect(find.text('Done'), findsOneWidget);
    expect(find.byType(ReceiptPaper), findsOneWidget);
  });
}
