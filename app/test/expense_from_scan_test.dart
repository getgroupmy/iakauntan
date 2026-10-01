import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/core/providers.dart';
import 'package:iakauntan/src/core/searchable_picker.dart';
import 'package:iakauntan/src/core/theme.dart';
import 'package:iakauntan/src/data/models.dart';
import 'package:iakauntan/src/data/ocr_repository.dart';
import 'package:iakauntan/src/data/repository.dart';
import 'package:iakauntan/src/features/expenses/expenses_screen.dart';
import 'package:iakauntan/src/features/shared/receipt_capture.dart';

/// A read receipt reaches the expense form's boxes.
///
/// `scanned_expense_test.dart` asserts the mapping. This asserts the
/// WIRING, and there is one thing here that no unit test can reach: the
/// tax codes, the payment modes and the company's currency are AWAITED.
/// At `initState` nothing has watched any of those providers — the
/// first `ref.watch` of each is in `build` — so reading them there
/// yields the loading state, and the tax code would never be matched
/// and the payment mode never accepted, silently, while every
/// assertion about the mapping still passed.
void main() {
  final codes = [
    TaxCode(
      id: 'sst6',
      code: 'SST6',
      name: 'Service tax 6%',
      rate: 6,
      taxTypeCode: 'SST',
    ),
  ];

  const modes = [
    {'code': '01', 'description': 'Cash'},
    {'code': '02', 'description': 'Cheque'},
    {'code': '03', 'description': 'Bank transfer'},
  ];

  /// A payment voucher, read into the eight configured columns.
  const voucher = OcrExtraction(
    supplierName: 'Pejabat Tanah',
    documentNo: 'IGNORED',
    fields: {
      'expense_date': '2026-03-04',
      'reference': 'PV-1187',
      'description': 'Being payment of land search fee',
      'payment_mode_code': '02',
      'amount': '1000.00',
      'tax_amount': '60.00',
      'total_amount': '1060.00',
    },
  );

  late _FakeRepo repo;

  Widget wrap() => ProviderScope(
    overrides: [
      expensesProvider.overrideWith((ref) async => []),
      canPostProvider.overrideWithValue(true),
      accountsProvider.overrideWith((ref) async => <Account>[
        Account(
          id: 'a-1',
          code: '6100',
          name: 'Disbursements',
          accountType: 'expense',
          accountSubtype: 'operating_expense',
        ),
      ]),
      // One to pay from. Empty until `0727` made "Paid from" a
      // condition of saving — a form with no bank account on offer
      // cannot record an expense at all now, which is the cost of the
      // rule and is why the picker can create one inline.
      bankAccountsProvider.overrideWith(
        (ref) async => [
          {'id': 'b-1', 'name': 'Maybank Current', 'bank_name': 'Maybank'},
        ],
      ),
      paymentModesProvider.overrideWith((ref) async => modes),
      projectsProvider.overrideWith((ref) async => []),
      departmentsProvider.overrideWith((ref) async => []),
      taxCodesProvider.overrideWith((ref) async => codes),
      mattersProvider.overrideWith((ref, arg) async => <Matter>[]),
      currentOrgProvider.overrideWith(
        (ref) async => Organization(id: 'o1', name: 'Kedai Kita', slug: 'k'),
      ),
      repoProvider.overrideWithValue(repo),
    ],
    child: MaterialApp(
      theme: AppTheme.light(),
      home: const ExpensesScreen(),
    ),
  );

  Future<void> openForm(WidgetTester tester, OcrExtraction? read) async {
    tester.view.physicalSize = const Size(412, 1800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    repo = _FakeRepo();
    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();
    final context = tester.element(find.byType(ExpensesScreen));
    unawaited(showExpenseFromScan(
      context,
      StagedReceipt(
        attachmentId: 'att-1',
        placeholderId: 'ph-1',
        read: read,
      ),
    ));
    await tester.pumpAndSettle();
  }

  String? boxText(WidgetTester tester, String label) {
    final field = find.widgetWithText(TextFormField, label);
    if (field.evaluate().isEmpty) return null;
    return tester.widget<TextField>(
      find.descendant(of: field.first, matching: find.byType(TextField)),
    ).controller?.text;
  }

  testWidgets('the words and the figures the reader answered', (tester) async {
    await openForm(tester, voucher);

    // The reader's own sentence, not the supplier-and-number pairing
    // the form used to build.
    expect(boxText(tester, 'Description'), 'Being payment of land search fee');
    // Its reference, not `document_no`.
    expect(boxText(tester, 'Reference'), 'PV-1187');
    // The NET, because a tax code was matched and the form adds the tax
    // back from its rate.
    expect(boxText(tester, 'Amount *'), '1000.00');
    expect(find.text('04/03/2026'), findsOneWidget);
  });

  testWidgets('the tax code its figures reproduce is chosen', (tester) async {
    // 6% of 1000.00 is 60.00, which is what the voucher prints. This is
    // also the assertion that proves the codes were awaited: read
    // instead, the list is null at `initState` and nothing matches.
    await openForm(tester, voucher);

    // `TaxCode.pickerLabel`: the code and its rate.
    expect(find.text('SST6 (6%)'), findsWidgets);
  });

  testWidgets('and the whole of it reaches the repository', (tester) async {
    // Drawing a value and sending it are different things.
    await openForm(tester, voucher);

    await tester.tap(find.descendant(
      of: find.ancestor(
        of: find.text('Expense account *'),
        matching: find.byType(SearchablePicker<String>),
      ),
      matching: find.byType(TextFormField),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('6100 — Disbursements').last);
    await tester.pumpAndSettle();

    await tester.tap(find.descendant(
      of: find.ancestor(
        of: find.text('Paid from'),
        matching: find.byType(SearchablePicker<String>),
      ),
      matching: find.byType(TextFormField),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Maybank Current').last);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Record and post'));
    await tester.pumpAndSettle();

    expect(repo.called, isTrue,
        reason: 'nothing pressed Save, so nothing was asserted');
    expect(repo.sawBank, 'b-1');
    expect(repo.sawAmount, 1000.00);
    // Computed by the form from the matched code's rate, and stored.
    expect(repo.sawTax, 60.00);
    expect(repo.sawTaxCode, 'sst6');
    expect(repo.sawMode, '02');
    expect(repo.sawReference, 'PV-1187');
    expect(repo.sawDescription, 'Being payment of land search fee');
    expect(repo.sawDate, DateTime(2026, 3, 4));
  });

  testWidgets('a tax nothing matches records what was actually paid', (
    tester,
  ) async {
    // The behaviour this changes. 9% is Singapore's and this chart
    // knows only 6%, so no code is chosen — and the amount box holds
    // the TOTAL rather than the net, because an expense of 1000.00 on
    // a payment of 1090.00 is ninety ringgit missing from the ledger
    // with nothing on screen saying so.
    await openForm(
      tester,
      const OcrExtraction(fields: {
        'amount': '1000.00',
        'tax_amount': '90.00',
        'total_amount': '1090.00',
      }),
    );

    expect(boxText(tester, 'Amount *'), '1090.00');
  });

  testWidgets('a document in another currency says so on the form', (
    tester,
  ) async {
    // `recordExpense` sets neither `currency` nor `exchange_rate`, so
    // this figure is about to be recorded as ringgit at a rate of 1.
    await openForm(
      tester,
      const OcrExtraction(
        fields: {'currency': 'USD', 'total_amount': '42.50'},
      ),
    );

    expect(find.byKey(const ValueKey('expense-foreign-currency')),
        findsOneWidget);
    expect(find.textContaining('in USD'), findsOneWidget);
  });

  testWidgets('and an ordinary ringgit receipt says nothing', (tester) async {
    // The control. A banner on every scan is a banner nobody reads.
    await openForm(
      tester,
      const OcrExtraction(
        fields: {'currency': 'MYR', 'total_amount': '42.50'},
      ),
    );

    expect(find.byKey(const ValueKey('expense-foreign-currency')), findsNothing);
  });

  // `0727`. Asked for: "make the paid from required when recording an
  // expense".
  //
  // This is the assertion that the rule is WIRED IN, not merely
  // written: `paidFromProblem` has its own unit test, and a mutant that
  // deleted the call to it from `_save` survived that test completely —
  // the rule was correct and reached nothing. The expense would have
  // saved, posted, and been credited to the 1120 control account where
  // no reconciliation could ever find it.
  testWidgets('and nothing is recorded until it says where the money came '
      'from', (tester) async {
    await openForm(tester, voucher);

    await tester.tap(find.descendant(
      of: find.ancestor(
        of: find.text('Expense account *'),
        matching: find.byType(SearchablePicker<String>),
      ),
      matching: find.byType(TextFormField),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('6100 — Disbursements').last);
    await tester.pumpAndSettle();

    // Everything else answered, and "Paid from" deliberately not.
    await tester.tap(find.text('Record and post'));
    await tester.pumpAndSettle();

    expect(repo.called, isFalse,
        reason: 'an expense was recorded without saying what paid for it');
    // And says what to do about it, on the screen, rather than leaving
    // a button that appears to do nothing.
    expect(find.textContaining('Choose the account'), findsOneWidget);
  });

  testWidgets('a capture that could not be read fills nothing', (
    tester,
  ) async {
    // The file is kept and the form opens empty rather than half-filled
    // with a previous receipt's figures.
    await openForm(tester, null);

    expect(boxText(tester, 'Description'), '');
    expect(boxText(tester, 'Reference'), '');
    expect(boxText(tester, 'Amount *'), '');
  });
}

class _FakeRepo implements Repo {
  bool called = false;
  double? sawAmount;
  double? sawTax;
  String? sawTaxCode;
  String? sawMode;
  String? sawBank;
  String? sawReference;
  String? sawDescription;
  DateTime? sawDate;

  @override
  String get orgId => 'org-1';

  @override
  Future<String> recordExpense({
    required String accountId,
    required double amount,
    required DateTime date,
    String? description,
    String? contactId,
    String? bankAccountId,
    String? paymentModeCode,
    String? taxCodeId,
    double taxAmount = 0,
    String? reference,
    String? projectCode,
    String? departmentCode,
    String? matterId,
    List<Map<String, dynamic>>? split,
  }) async {
    called = true;
    sawAmount = amount;
    sawTax = taxAmount;
    sawTaxCode = taxCodeId;
    sawMode = paymentModeCode;
    sawBank = bankAccountId;
    sawReference = reference;
    sawDescription = description;
    sawDate = date;
    return 'exp-1';
  }

  /// A Dart extension method binds to the static type, so a fake cannot
  /// override one; the calls that go through an extension land here.
  @override
  Future<dynamic> callRpc(String fn, {Map<String, dynamic>? params}) async =>
      null;

  // `refileAttachment` is deliberately NOT here. It is on the `RepoOcr`
  // EXTENSION and reaches `client` directly, so a fake cannot stand in
  // for it -- an `@override` on it is not one, which the analyzer says
  // by name. It therefore throws through `noSuchMethod` when the form
  // files the receipt onto the saved expense, AFTER `recordExpense` has
  // been called with everything asserted below; `runWithFeedback`
  // catches it and reports a failed save. `expect(repo.called, isTrue)`
  // is what stops that from making these assertions vacuous.

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
    'the expense form called Repo.${invocation.memberName}, '
    'which this fake does not answer',
  );
}
