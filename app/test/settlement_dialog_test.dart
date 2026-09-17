import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/core/providers.dart';
import 'package:iakauntan/src/core/theme.dart';
import 'package:iakauntan/src/data/models.dart';
import 'package:iakauntan/src/data/repository.dart';
import 'package:iakauntan/src/features/documents/settlement_dialog.dart';

/// Receiving money and paying it out.
///
/// 1,040 lines and no test, and it is the screen where money is applied
/// to invoices. `settlement_discount_test.dart` has the discount
/// arithmetic and `fx` has its own; what only lives in this widget is
/// how a receipt is assembled before it is posted.
///
/// THE CHARGES GO THE OTHER WAY ROUND. A receipt of 1,000 with 15 of
/// bank charges puts 985 in the bank; a payment of 1,000 with 15 of
/// charges takes 1,015 out of it. The same number, the same field, and
/// the sign is the difference between reconciling and not. Both
/// directions are asserted, because either sentence alone passes
/// against a dialog that always adds.
///
/// MONEY TICKED AGAINST ONE CUSTOMER MUST NOT FOLLOW TO ANOTHER.
/// Changing the contact clears the allocations, the discounts and the
/// offers. Without that, ticking Aminah's invoice and then realising it
/// was Lim who paid leaves Aminah's document id in the map and posts
/// the receipt against her.
///
/// AND NOTHING IS APPLIED BEYOND WHAT IS OWED. The amount is clamped to
/// the document's balance, so over-typing settles the invoice and no
/// more. The database refuses the rest — `0385` raises "the cash and
/// the discount come to more than % still owes" — and this is the
/// screen not building it in the first place.
void main() {
  Contact contact({
    String id = 'c1',
    String name = 'Kedai Runcit Aminah',
    String code = 'C-0001',
  }) => Contact(
    id: id,
    code: code,
    name: name,
    contactType: 'customer',
  );

  BusinessDocument invoice({
    String id = 'd1',
    String docNo = 'INV-0001',
    num total = 1000,
    num balance = 1000,
    String currency = 'MYR',
    double rate = 1,
  }) => BusinessDocument(
    id: id,
    docType: 'invoice',
    docNo: docNo,
    docDate: DateTime(2026, 9, 1),
    contactId: 'c1',
    contactName: 'Kedai Runcit Aminah',
    dueDate: DateTime(2026, 10, 1),
    currency: currency,
    exchangeRate: rate,
    totalAmount: total.toDouble(),
    balanceAmount: balance.toDouble(),
    paidAmount: (total - balance).toDouble(),
    status: 'posted',
  );

  /// Open documents per contact, so switching contacts really does
  /// change what is on offer.
  late Map<String, List<BusinessDocument>> open;

  setUp(() {
    open = {
      'c1': [invoice()],
      'c2': [invoice(id: 'd2', docNo: 'INV-0002', total: 400, balance: 400)],
    };
  });

  Widget wrap({
    required DocKind kind,
    List<Contact> contacts = const [],
    String? preselect,
    Map<String, Map<String, dynamic>> offers = const {},
    bool legal = false,
  }) => ProviderScope(
    overrides: [
      repoProvider.overrideWithValue(_FakeRepo(offers)),
      contactsProvider((type: kind.contactType, search: '')).overrideWith(
        (ref) async => contacts,
      ),
      outstandingProvider.overrideWith(
        (ref, args) async => open[args.contactId] ?? const [],
      ),
      bankAccountsProvider.overrideWith((ref) async => const []),
      paymentModesProvider.overrideWith(
        (ref) async => const [
          {'code': '03', 'description': 'Bank transfer'},
        ],
      ),
      // No legal module, so the client-money section is absent. Its
      // own case is asserted separately.
      enabledModulesProvider.overrideWith(
        (ref) async => legal ? const {'legal'} : const <String>{},
      ),
      myModuleAccessProvider.overrideWith(
        (ref) async => const <String, String>{},
      ),
      // Present in BOTH cases. A client with no open matter sees no
      // section whatever the module says, so a fixture with none makes
      // the "not asked" test pass for the wrong reason -- it was
      // written that way first and the mutation run said so.
      clientMattersProvider.overrideWith(
        (ref, id) async => [
          Matter(
            id: 'm1',
            matterNo: 'LIT/2026/001',
            name: 'Sale of shophouse',
            clientId: id,
            status: 'open',
            matterType: 'conveyancing',
          ),
        ],
      ),
    ],
    child: MaterialApp(
      theme: AppTheme.light(),
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: Consumer(
              builder: (context, ref, _) => ElevatedButton(
                onPressed: () => showSettlementDialog(
                  context,
                  ref,
                  kind: kind,
                  documentId: preselect,
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    ),
  );

  Future<void> show(
    WidgetTester tester, {
    DocKind kind = DocKind.sales,
    List<Contact>? contacts,
    String? preselect,
    Map<String, Map<String, dynamic>> offers = const {},
    bool legal = false,
  }) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1000, 1400);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      wrap(
        kind: kind,
        contacts:
            contacts ??
            [contact(), contact(id: 'c2', name: 'Encik Lim', code: 'C-0002')],
        preselect: preselect,
        offers: offers,
        legal: legal,
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  /// Picks a contact by name in the searchable picker.
  Future<void> choose(WidgetTester tester, String name) async {
    await tester.tap(find.text('Customer *'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(name).last);
    await tester.pumpAndSettle();
  }

  /// Types into the amount box on the row for [docNo].
  Future<void> allocate(
    WidgetTester tester,
    String docNo,
    String amount,
  ) async {
    final row = find.ancestor(
      of: find.textContaining(docNo),
      matching: find.byType(Row),
    );
    await tester.enterText(
      find.descendant(of: row.first, matching: find.byType(TextField)).first,
      amount,
    );
    await tester.pumpAndSettle();
  }

  bool saveEnabled(WidgetTester tester, String label) =>
      tester.widget<ButtonStyleButton>(find.widgetWithText(FilledButton, label))
          .onPressed !=
      null;

  group('before anything is allocated', () {
    testWidgets('a receipt cannot be recorded', (tester) async {
      await show(tester);
      await choose(tester, 'Kedai Runcit Aminah');

      expect(saveEnabled(tester, 'Record receipt'), isFalse);
    });

    testWidgets('and the total settled is nothing', (tester) async {
      await show(tester);
      await choose(tester, 'Kedai Runcit Aminah');

      expect(find.text('Total being settled'), findsOneWidget);
      expect(find.text('RM 0.00'), findsOneWidget);
    });
  });

  group('the total being settled', () {
    testWidgets('is what was allocated, not what is owed', (tester) async {
      // A part payment. The invoice still says 1,000 and the receipt is
      // 400 — a footer showing the balance would be the commonest way
      // to record the wrong amount.
      await show(tester);
      await choose(tester, 'Kedai Runcit Aminah');
      await allocate(tester, 'INV-0001', '400');

      expect(find.text('RM 400.00'), findsOneWidget);
      expect(saveEnabled(tester, 'Record receipt'), isTrue);
    });

    testWidgets('and is capped at what the document still owes',
        (tester) async {
      // Over-typing does not over-apply. `0385` refuses the rest in
      // SQL — "the cash and the discount come to more than % still
      // owes" — and this is the screen not building it.
      await show(tester);
      await choose(tester, 'Kedai Runcit Aminah');
      await allocate(tester, 'INV-0001', '2500');

      expect(find.text('RM 1,000.00'), findsWidgets);
      expect(find.text('RM 2,500.00'), findsNothing);
    });
  });

  group('bank charges', () {
    Future<void> withCharges(WidgetTester tester, String amount) async {
      await tester.enterText(
        find.widgetWithText(TextField, 'Bank charges'),
        amount,
      );
      await tester.pumpAndSettle();
    }

    testWidgets('come OUT of a receipt', (tester) async {
      // 1,000 received less 15 of charges is 985 in the bank. The
      // customer is still credited 1,000 — the charge is the bank's.
      await show(tester);
      await choose(tester, 'Kedai Runcit Aminah');
      await allocate(tester, 'INV-0001', '1000');
      await withCharges(tester, '15');

      expect(
        find.text('Bank will be debited RM 985.00 after charges.'),
        findsOneWidget,
      );
    });

    testWidgets('and are ADDED to a payment', (tester) async {
      // The same field, the same number, the other direction. Asserted
      // beside the receipt case because either alone passes against a
      // dialog that always subtracts.
      open = {
        'c1': [invoice(docNo: 'BILL-01')],
      };
      await show(
        tester,
        kind: DocKind.purchase,
        contacts: [contact(name: 'Syarikat Maju', code: 'S-0001')],
      );
      await tester.tap(find.text('Supplier *'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Syarikat Maju').last);
      await tester.pumpAndSettle();
      await allocate(tester, 'BILL-01', '1000');
      await withCharges(tester, '15');

      expect(
        find.text('Bank will be credited RM 1,015.00 including charges.'),
        findsOneWidget,
      );
    });

    testWidgets('and say nothing when there are none', (tester) async {
      // The control. A line about charges on every receipt is a
      // sentence people stop reading.
      await show(tester);
      await choose(tester, 'Kedai Runcit Aminah');
      await allocate(tester, 'INV-0001', '1000');

      expect(find.textContaining('after charges'), findsNothing);
      expect(find.textContaining('including charges'), findsNothing);
    });
  });

  testWidgets('changing the customer drops what was ticked against the '
      'last one', (tester) async {
    // The money bug this guards. Ticking Aminah's invoice and then
    // realising it was Lim who paid must not post 1,000 against
    // Aminah's account under Lim's name.
    await show(tester);
    await choose(tester, 'Kedai Runcit Aminah');
    await allocate(tester, 'INV-0001', '1000');
    expect(find.text('RM 1,000.00'), findsWidgets);

    await choose(tester, 'Encik Lim');

    // Lim's own invoice is on offer and nothing is allocated to it.
    expect(find.textContaining('INV-0002'), findsOneWidget);
    expect(find.textContaining('INV-0001'), findsNothing);
    expect(find.text('RM 0.00'), findsOneWidget);
    expect(saveEnabled(tester, 'Record receipt'), isFalse);
  });

  testWidgets('and drops the DISCOUNT taken against the last one too',
      (tester) async {
    // Worse than a stale allocation. A settlement discount posts its own
    // journal -- Dr 4300 sales discounts, Cr receivable, against the
    // contact on the invoice -- so one carried to the next customer's
    // receipt writes off part of somebody else's debt.
    //
    // `_discounts.clear()` sits on the line after `_allocations.clear()`
    // and the mutation run showed nothing was asserting it.
    await show(
      tester,
      offers: {
        'd1': {
          'deadline': '2099-01-01',
          'discount': 20.0,
          'pay_now': 980.0,
          'still_open': true,
        },
      },
    );
    await choose(tester, 'Kedai Runcit Aminah');

    // The offer is only drawn on a row being settled: a line on every
    // row saying no discount is available is noise pretending to be
    // information, so the row has to carry an amount first.
    await allocate(tester, 'INV-0001', '1000');
    await tester.tap(find.text('Take it'));
    await tester.pumpAndSettle();
    // The cash is the balance less the discount, which together settle
    // the invoice exactly.
    expect(find.text('RM 980.00'), findsWidgets);
    expect(find.text('Undo'), findsOneWidget);

    await choose(tester, 'Encik Lim');

    expect(find.text('Undo'), findsNothing);
    expect(find.text('RM 0.00'), findsOneWidget);
  });

  testWidgets('the currency is read off what is being SETTLED, not off '
      'everything open', (tester) async {
    // A customer with a ringgit invoice and a dollar one is ordinary.
    // Settling only the ringgit one is a ringgit receipt; counting the
    // dollar invoice the customer has not paid would declare a currency
    // conflict and refuse a receipt there is nothing wrong with.
    open = {
      'c1': [
        invoice(docNo: 'INV-0001'),
        invoice(
          id: 'd9',
          docNo: 'INV-0009',
          total: 500,
          balance: 500,
          currency: 'USD',
          rate: 4.5,
        ),
      ],
    };
    await show(tester, contacts: [contact()]);
    await choose(tester, 'Kedai Runcit Aminah');
    await allocate(tester, 'INV-0001', '1000');

    expect(find.textContaining('different currencies'), findsNothing);
    expect(saveEnabled(tester, 'Record receipt'), isTrue);
  });

  testWidgets('and says so when two currencies really are being settled',
      (tester) async {
    // The control, and the rule itself: one payment cannot settle
    // documents raised in two currencies, so it is refused with both
    // document numbers named.
    open = {
      'c1': [
        invoice(docNo: 'INV-0001'),
        invoice(
          id: 'd9',
          docNo: 'INV-0009',
          total: 500,
          balance: 500,
          currency: 'USD',
          rate: 4.5,
        ),
      ],
    };
    await show(tester, contacts: [contact()]);
    await choose(tester, 'Kedai Runcit Aminah');
    await allocate(tester, 'INV-0001', '1000');
    await allocate(tester, 'INV-0009', '500');

    expect(find.textContaining('different currencies'), findsOneWidget);
    expect(saveEnabled(tester, 'Record receipt'), isFalse);
  });

  testWidgets('a discount is offered only on a row being settled',
      (tester) async {
    // "A line on every row saying no discount is available is noise
    // pretending to be information" -- the screen's own words. The same
    // goes for one saying a discount IS available on an invoice nobody
    // is paying.
    open = {
      'c1': [
        invoice(docNo: 'INV-0001'),
        invoice(id: 'd2', docNo: 'INV-0002', total: 400, balance: 400),
      ],
    };
    const offer = {
      'deadline': '2099-01-01',
      'discount': 20.0,
      'pay_now': 980.0,
      'still_open': true,
    };
    await show(
      tester,
      contacts: [contact()],
      offers: const {'d1': offer, 'd2': offer},
    );
    await choose(tester, 'Kedai Runcit Aminah');
    await allocate(tester, 'INV-0001', '1000');

    // One row is being settled, and exactly one offer is on screen.
    expect(find.text('Take it'), findsOneWidget);
  });

  testWidgets('a document opened from its own page arrives allocated',
      (tester) async {
    // Coming here from an invoice means settling THAT invoice, and
    // making somebody tick the row they just came from is a step that
    // exists only because the screen did not carry the id across.
    await show(tester, preselect: 'd1');
    await choose(tester, 'Kedai Runcit Aminah');

    expect(find.text('RM 1,000.00'), findsWidgets);
    expect(saveEnabled(tester, 'Record receipt'), isTrue);
  });

  testWidgets('a firm without the legal module is not asked about client '
      'money', (tester) async {
    // `0549`. Three destinations for a receipt and two sources for a
    // payment are a solicitor's problem; on every other business they
    // are a section asking a question that has no answer.
    await show(tester);
    await choose(tester, 'Kedai Runcit Aminah');

    // `find.text`, and the exact capital the widget uses. This was
    // written as `textContaining('client account')`, which is
    // lower-case and could therefore never match `Text('Client
    // account')` -- an assertion that passes whatever the screen does.
    // The mutation run caught it; nothing else would have.
    expect(find.text('Client account'), findsNothing);
  });

  testWidgets('and a firm that holds it is', (tester) async {
    // The control for the line above.
    await show(tester, legal: true);
    await choose(tester, 'Kedai Runcit Aminah');

    expect(find.text('Client account'), findsOneWidget);
  });
}

/// ## Two mutants that survive here, and why they are equivalent
///
/// Removing `_discounts.clear()` or `_offers.clear()` from the contact
/// picker's `onChanged` cannot be observed, and the reason is worth
/// writing down rather than chasing with an assertion that would have
/// to reach into private state.
///
/// Both maps are keyed by DOCUMENT ID. `_allocations.clear()` runs on
/// the same line and IS asserted, so the stale row carries no amount:
/// the save builds its allocations from `_allocations.entries` where
/// the value is above zero, so a stale discount is never sent, and the
/// offer line is drawn only on a row being settled, so a stale offer is
/// never shown. The next customer's documents have different ids in any
/// case.
///
/// So the two `clear()` calls are tidiness rather than the rule. The
/// rule is `_allocations.clear()`, and money ticked against one
/// customer following to another is asserted directly above.
///
/// Recorded per the header of `scripts/mutate.py`.

/// Only what this dialog asks for.
///
/// The discount offers are the DATABASE's -- `0385`'s
/// `settlement_discount_available` -- because a screen that offered one
/// the ledger would refuse is worse than one that offered none. So the
/// only way to reach the discount path in a widget test is to answer
/// that call.
class _FakeRepo implements Repo {
  _FakeRepo(this.offers);

  /// Keyed by document id, shaped the way the RPC returns a row.
  final Map<String, Map<String, dynamic>> offers;

  @override
  Future<Map<String, dynamic>?> settlementDiscount(
    String documentId, {
    DateTime? asAt,
  }) async => offers[documentId];

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
    'the settlement dialog called Repo.${invocation.memberName}, which '
    'this fake does not answer',
  );
}
