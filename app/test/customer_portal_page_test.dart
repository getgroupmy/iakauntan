import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/core/theme.dart';
import 'package:iakauntan/src/features/documents/customer_portal_page.dart';
import 'package:iakauntan/src/features/documents/customer_portal_summary.dart';

/// The account page a customer opens from their link, drawn at the size
/// of the phone they open it on.
///
/// 0797: the headline added every balance together under the company's
/// currency, and every row was formatted in it too -- a dollar invoice
/// read "RM 100.00". The words are asserted in
/// `customer_portal_summary_test.dart`; this asserts the page shows the
/// words it is given, where it is given them.
void main() {
  PortalAccount mixed() => PortalAccount.fromMap({
    'state': 'open',
    'company': {'name': 'Sinar Teknologi Sdn Bhd'},
    'contact': {'name': 'Buyer Bhd'},
    'currency': 'MYR',
    'total_outstanding': null,
    'totals': [
      {'currency': 'MYR', 'amount': 100},
      {'currency': 'USD', 'amount': 100},
    ],
    'invoices': [
      {
        'id': 'i1', 'doc_no': 'INV-1', 'currency': 'MYR',
        'balance_amount': 100, 'total_amount': 100,
        'overdue': false, 'due_date': '2026-02-01',
      },
      {
        'id': 'i2', 'doc_no': 'INV-2', 'currency': 'USD',
        'balance_amount': 100, 'total_amount': 250,
        'overdue': false, 'due_date': '2026-02-15',
      },
    ],
  });

  Future<void> pump(WidgetTester tester, PortalAccount a) async {
    // A phone, portrait: the window a test gets otherwise is landscape.
    tester.view.physicalSize = const Size(412, 830);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light(),
      home: Scaffold(
        body: SingleChildScrollView(
          child: PortalAccountView(
            account: a,
            busyId: null,
            onOpen: (_) async {},
            onRefresh: () {},
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  Finder inRow(String id, String text) => find.descendant(
    of: find.byKey(ValueKey('portal-invoice-$id')),
    matching: find.text(text),
  );

  testWidgets('owed in two currencies, the headline says each', (tester) async {
    await pump(tester, mixed());
    final headline = find.byKey(const ValueKey('portal-outstanding'));
    expect(tester.widget<Text>(headline).data, 'RM 100.00 · USD 100.00');
    // And it fits the phone it is read on.
    expect(tester.getRect(headline).right, lessThanOrEqualTo(412));
    expect(tester.takeException(), isNull);
  });

  testWidgets('each row is in its own currency', (tester) async {
    await pump(tester, mixed());
    expect(inRow('i1', 'RM 100.00'), findsOneWidget);
    expect(inRow('i2', 'USD 100.00'), findsOneWidget);
    expect(inRow('i2', 'RM 100.00'), findsNothing);
    expect(inRow('i2', 'of USD 250.00'), findsOneWidget);
  });
}
