import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/core/providers.dart';
import 'package:iakauntan/src/core/theme.dart';
import 'package:iakauntan/src/features/documents/intercompany_screen.dart';

/// What an accountant in the subsidiary is shown about invoices the
/// holding company has addressed to them.
///
/// The rules are in 0146 and asserted in
/// `supabase/tests/intercompany_billing.sql` — the database is what
/// decides which documents are visible across a company boundary, and a
/// screen cannot prove that. What is asserted here is the three states
/// this list has, because two of them are ones where the obvious design
/// shows a button that cannot work.
void main() {
  Map<String, dynamic> invoice({
    String id = 'd1',
    String from = 'IC Holdings Sdn Bhd',
    double total = 10800,
    double tax = 800,
    String? supplierContactId = 'c1',
    bool billed = false,
    String? billId,
  }) => {
    'sales_document_id': id,
    'from_org_id': 'a1',
    'from_org': from,
    'doc_no': 'INV-IC-1',
    'doc_date': '2026-08-15',
    'currency': 'MYR',
    'subtotal': total - tax,
    'tax_amount': tax,
    'total_amount': total,
    'supplier_contact_id': supplierContactId,
    'bill_id': billId,
    'already_billed': billed,
  };

  Widget harness(List<Map<String, dynamic>> rows) => ProviderScope(
    overrides: [
      repoProvider.overrideWithValue(null),
      intercompanyInboxProvider.overrideWith((ref) async => rows),
    ],
    child: MaterialApp(
      theme: AppTheme.light(),
      home: const IntercompanyScreen(),
    ),
  );

  testWidgets('an invoice waiting to be billed is offered the button', (
    tester,
  ) async {
    await tester.pumpWidget(harness([invoice()]));
    await tester.pumpAndSettle();

    expect(find.text('IC Holdings Sdn Bhd'), findsOneWidget);
    expect(find.byKey(const ValueKey('accept-d1')), findsOneWidget);
  });

  testWidgets('one with no supplier on this side is told what is missing '
      'rather than shown a button that fails', (tester) async {
    // A bill has to be owed to somebody on this company's own books. The
    // database refuses without one, so the screen says so first.
    await tester.pumpWidget(harness([invoice(supplierContactId: null)]));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('accept-d1')), findsNothing);
    expect(find.textContaining('Add a supplier'), findsWidgets);
  });

  testWidgets('and one already dealt with stays on the list, saying so', (
    tester,
  ) async {
    // Filtered out, an accountant looking for last month's invoice from
    // the holding company finds nothing and wonders. Left visible, they
    // find it and see it was handled.
    await tester.pumpWidget(harness([invoice(billed: true, billId: 'b1')]));
    await tester.pumpAndSettle();

    expect(find.text('Already billed here'), findsOneWidget);
    expect(find.text('Open the bill'), findsOneWidget);
    expect(find.byKey(const ValueKey('accept-d1')), findsNothing);
  });

  testWidgets('an empty list explains what would put something in it', (
    tester,
  ) async {
    await tester.pumpWidget(harness(const []));
    await tester.pumpAndSettle();

    expect(find.text('Nothing from the group'), findsOneWidget);
    // The addressing rule, said where somebody wondering why the list is
    // empty will read it.
    expect(find.textContaining('whose record points at it'), findsOneWidget);
  });

  testWidgets('the tax is shown, because it is what a group has to '
      'eliminate later', (tester) async {
    await tester.pumpWidget(harness([invoice()]));
    await tester.pumpAndSettle();

    expect(find.textContaining('tax'), findsWidgets);
  });

  testWidgets('and an untaxed invoice does not say "tax 0.00"', (tester) async {
    await tester.pumpWidget(harness([invoice(total: 5000, tax: 0)]));
    await tester.pumpAndSettle();

    expect(find.textContaining('tax'), findsNothing);
  });
}
