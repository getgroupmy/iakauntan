import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/core/providers.dart';
import 'package:iakauntan/src/core/theme.dart';
import 'package:iakauntan/src/data/models.dart';
import 'package:iakauntan/src/features/documents/apply_on_account.dart';

/// Money already banked, set against a document raised later.
///
/// The receipts screen has told people since it was written that what is
/// left on a receipt "can be set against a future invoice", and until
/// 0465 nothing in the app could do it. What is asserted here is the
/// screen that keeps the promise: it offers the contact's open
/// documents, it counts down what is left of the money, and it will not
/// let somebody spend more of a receipt than the receipt holds — which
/// the database refuses anyway, and which nobody should have to find out
/// from a server error.
void main() {
  BusinessDocument invoice(String id, String no, double balance) =>
      BusinessDocument(
        id: id,
        docType: 'invoice',
        docNo: no,
        docDate: DateTime(2026, 8, 1),
        contactId: 'c1',
        totalAmount: balance,
        balanceAmount: balance,
        status: 'posted',
      );

  Widget harness(List<BusinessDocument> open, {double available = 1000}) =>
      ProviderScope(
        overrides: [
          repoProvider.overrideWithValue(null),
          outstandingProvider.overrideWith((ref, args) async => open),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showApplyOnAccount(
                  context,
                  settlementId: 'r1',
                  isSales: true,
                  contactId: 'c1',
                  available: available,
                  currency: 'MYR',
                ),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );

  Future<void> open(WidgetTester tester, Widget w) async {
    await tester.pumpWidget(w);
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
  }

  testWidgets('it offers what the customer still owes', (tester) async {
    await open(tester, harness([
      invoice('d1', 'INV-1', 400),
      invoice('d2', 'INV-2', 300),
    ]));

    expect(find.text('RM 1,000.00 on account'), findsOneWidget);
    expect(find.text('INV-1'), findsOneWidget);
    expect(find.text('INV-2'), findsOneWidget);
  });

  testWidgets('nothing is ticked to begin with, and Apply is dead', (
    tester,
  ) async {
    await open(tester, harness([invoice('d1', 'INV-1', 400)]));

    final button = tester.widget<ButtonStyleButton>(
      find.byKey(const ValueKey('apply-on-account')),
    );
    expect(button.onPressed, isNull);
  });

  testWidgets('it counts down what would be left on account', (tester) async {
    await open(tester, harness([
      invoice('d1', 'INV-1', 400),
      invoice('d2', 'INV-2', 300),
    ]));

    await tester.tap(find.byType(Checkbox).first);
    await tester.pumpAndSettle();
    expect(find.text('RM 600.00 would be left on account'), findsOneWidget);

    await tester.tap(find.byType(Checkbox).last);
    await tester.pumpAndSettle();
    expect(find.text('RM 300.00 would be left on account'), findsOneWidget);
  });

  testWidgets('and refuses to spend more of the receipt than it holds', (
    tester,
  ) async {
    // RM500 on account, RM900 of invoices in front of it. The database
    // refuses this too; being told before the round trip is the point.
    await open(tester, harness([
      invoice('d1', 'INV-1', 400),
      invoice('d2', 'INV-2', 500),
    ], available: 500));

    await tester.tap(find.byType(Checkbox).first);
    await tester.pumpAndSettle();
    await tester.tap(find.byType(Checkbox).last);
    await tester.pumpAndSettle();

    expect(
      find.text('RM 400.00 more than there is on account'),
      findsOneWidget,
    );
    final button = tester.widget<ButtonStyleButton>(
      find.byKey(const ValueKey('apply-on-account')),
    );
    expect(button.onPressed, isNull);
  });

  testWidgets('with nothing open it says the money stays where it is', (
    tester,
  ) async {
    await open(tester, harness(const []));
    expect(find.text('Nothing outstanding'), findsOneWidget);
    expect(find.textContaining('stays on account'), findsOneWidget);
  });
}
