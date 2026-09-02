import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/core/providers.dart';
import 'package:iakauntan/src/core/theme.dart';
import 'package:iakauntan/src/features/documents/group_payment_screen.dart';

/// One payment covering more than one company.
///
/// The money is asserted in `supabase/tests/group_payment.sql`, where
/// one call becomes one receipt per company and the refusals are read
/// by their messages. What is asserted here is the screen: that it
/// groups by company, that the running total is of what is ticked
/// rather than of what is listed, and that the button stays dead until
/// something is.
void main() {
  Map<String, dynamic> open(
    String id,
    String org,
    String orgName,
    String no,
    double balance,
  ) => {
    'org_id': org,
    'org_name': orgName,
    'doc_id': id,
    'doc_no': no,
    'doc_date': '2026-08-01',
    'due_date': '2026-08-31',
    'contact_id': 'c1',
    'contact_name': 'Kumpulan Awan',
    'currency': 'MYR',
    'total_amount': balance,
    'balance_amount': balance,
  };

  final across = [
    open('d1', 'o1', 'Awan Satu Sdn Bhd', 'INV-A1', 1000),
    open('d2', 'o1', 'Awan Satu Sdn Bhd', 'INV-A2', 250),
    open('d3', 'o2', 'Awan Dua Sdn Bhd', 'INV-B1', 2500),
  ];

  Widget harness(List<Map<String, dynamic>> rows, {bool canAdd = true}) =>
      ProviderScope(
    overrides: [
      repoProvider.overrideWithValue(null),
      openAcrossCompaniesProvider.overrideWith((ref, kind) async => rows),
      canAddCompanyProvider.overrideWith((_) async => canAdd),
    ],
    child: MaterialApp(
      theme: AppTheme.light(),
      home: const GroupPaymentScreen(),
    ),
  );

  testWidgets('the open documents are grouped by the company that owns them', (
    tester,
  ) async {
    await tester.pumpWidget(harness(across));
    await tester.pumpAndSettle();

    // Two companies, three documents. The company name is a heading,
    // not a column repeated on every line — a payment is split by
    // company, so that is what the eye has to be able to count.
    expect(find.text('Awan Satu Sdn Bhd'), findsOneWidget);
    expect(find.text('Awan Dua Sdn Bhd'), findsOneWidget);
    expect(find.textContaining('INV-A1'), findsOneWidget);
    expect(find.textContaining('INV-B1'), findsOneWidget);
  });

  testWidgets('nothing is selected to begin with, and the button is dead', (
    tester,
  ) async {
    await tester.pumpWidget(harness(across));
    await tester.pumpAndSettle();

    expect(find.text('Nothing selected'), findsOneWidget);
    // Found by key, not by type: `FilledButton.icon` builds a private
    // subclass and `find.byType` matches the exact runtime type.
    final button = tester.widget<ButtonStyleButton>(
      find.byKey(const ValueKey('group-payment-record')),
    );
    expect(button.onPressed, isNull);
  });

  testWidgets('the total is of what is ticked, across the companies ticked', (
    tester,
  ) async {
    await tester.pumpWidget(harness(across));
    await tester.pumpAndSettle();

    // One document from each company: 1,000 and 2,500.
    await tester.tap(find.byType(Checkbox).first);
    await tester.pumpAndSettle();
    await tester.tap(find.byType(Checkbox).last);
    await tester.pumpAndSettle();

    expect(find.text('RM 3,500.00'), findsOneWidget);
    expect(find.text('across 2 companies'), findsOneWidget);

    // Found by key, not by type: `FilledButton.icon` builds a private
    // subclass and `find.byType` matches the exact runtime type.
    final button = tester.widget<ButtonStyleButton>(
      find.byKey(const ValueKey('group-payment-record')),
    );
    expect(button.onPressed, isNotNull);
  });

  testWidgets('two documents in one company are one company, not two', (
    tester,
  ) async {
    await tester.pumpWidget(harness(across));
    await tester.pumpAndSettle();

    final boxes = find.byType(Checkbox);
    await tester.tap(boxes.at(0));
    await tester.pumpAndSettle();
    await tester.tap(boxes.at(1));
    await tester.pumpAndSettle();

    expect(find.text('RM 1,250.00'), findsOneWidget);
    expect(find.text('across 1 company'), findsOneWidget);
  });

  testWidgets('a part payment is the figure typed over the balance', (
    tester,
  ) async {
    await tester.pumpWidget(harness(across));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(Checkbox).first);
    await tester.pumpAndSettle();

    // The amount defaults to the whole balance, which is what most of
    // these are; a part payment is typed over it. Field 2, because the
    // bank reference and the note come before the first row.
    expect(find.text('RM 1,000.00'), findsOneWidget);
    await tester.enterText(find.byType(TextField).at(2), '400');
    await tester.pumpAndSettle();
    expect(find.text('RM 400.00'), findsOneWidget);
  });

  testWidgets('with nothing open it still offers to add a company', (
    tester,
  ) async {
    await tester.pumpWidget(harness(const []));
    await tester.pumpAndSettle();

    // The company that is not on the list is the one that has not been
    // set up yet, and the honest answer is the form that sets one up.
    expect(find.text('Nothing outstanding'), findsOneWidget);
    expect(find.text('Add a company'), findsOneWidget);
  });

  testWidgets('but not to an account that may not add one', (tester) async {
    await tester.pumpWidget(harness(const [], canAdd: false));
    await tester.pumpAndSettle();

    // 0486 makes a second company the Multi-Company module, and the
    // server is the one that decides. A button that opens a form which
    // refuses at Save is worse than no button: the person has typed a
    // company's details in by then.
    expect(find.text('Nothing outstanding'), findsOneWidget);
    expect(find.text('Company not listed?'), findsOneWidget);
    expect(find.text('Add a company'), findsNothing);
  });
}
