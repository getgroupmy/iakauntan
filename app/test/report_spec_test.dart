import 'package:flutter/material.dart' show DateTimeRange;
import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/features/reports/report_spec.dart';

/// The screen and the PDF both render these, so this is where the
/// arithmetic of every report actually lives. Row shapes are copied from
/// what the report functions in 0014/0016 return.
void main() {
  final range = DateTimeRange(
    start: DateTime(2026, 1, 1),
    end: DateTime(2026, 8, 11),
  );

  Map<String, dynamic> pl(String code, String name, String type, double amount,
          {String? subtype}) =>
      {
        'code': code,
        'name': name,
        'account_type': type,
        'account_subtype': subtype,
        'amount': amount,
      };

  group('profit and loss', () {
    final rows = [
      pl('4000', 'Sales', 'revenue', 100000),
      pl('5000', 'Purchases', 'expense', 60000, subtype: 'cost_of_sales'),
      pl('6000', 'Salaries', 'expense', 25000),
      pl('6100', 'Rent', 'expense', 5000),
    ];

    test('gross profit is revenue less cost of sales only', () {
      final spec = profitLossSpec(rows, range);
      final gross = spec.blocks.whereType<ReportHighlight>().first;
      expect(gross.label, 'Gross profit');
      expect(gross.value, 40000);
    });

    test('net profit takes the other expenses off the gross', () {
      final spec = profitLossSpec(rows, range);
      final net = spec.blocks.whereType<ReportHighlight>().last;
      expect(net.label, 'Net profit');
      expect(net.value, 10000);
    });

    test('cost of sales is not double counted as an expense', () {
      // It is an expense account with a subtype, so a filter on
      // account_type alone would put the 60,000 in both sections and
      // understate net profit by exactly that much.
      final spec = profitLossSpec(rows, range);
      final expenses = spec.blocks
          .whereType<ReportSection>()
          .firstWhere((s) => s.title == 'Expenses');
      expect(expenses.total, 30000);
      expect(expenses.lines.map((l) => l.code), isNot(contains('5000')));
    });

    test('a loss is carried through as a negative, not an absolute', () {
      final spec = profitLossSpec([
        pl('4000', 'Sales', 'revenue', 1000),
        pl('6000', 'Salaries', 'expense', 4000),
      ], range);
      expect(spec.blocks.whereType<ReportHighlight>().last.value, -3000);
    });

    test('the period is on the report, because a P&L without one is not one',
        () {
      expect(profitLossSpec(rows, range).subtitle, contains('2026'));
    });
  });

  group('balance sheet', () {
    Map<String, dynamic> bs(String code, String type, double balance) =>
        {'code': code, 'name': code, 'account_type': type, 'balance': balance};

    test('the check is assets less liabilities less equity', () {
      final spec = balanceSheetSpec([
        bs('1000', 'asset', 50000),
        bs('2000', 'liability', 20000),
        bs('3000', 'equity', 30000),
      ], DateTime(2026, 8, 11));
      expect(spec.blocks.whereType<ReportHighlight>().single.value, 0);
    });

    test('accounts sitting at zero are left off', () {
      final spec = balanceSheetSpec([
        bs('1000', 'asset', 50000),
        bs('1100', 'asset', 0),
      ], DateTime(2026, 8, 11));
      final assets = spec.blocks.whereType<ReportSection>().first;
      expect(assets.lines, hasLength(1));
    });
  });

  group('trial balance', () {
    Map<String, dynamic> tb(String code, double debit, double credit,
            double closing) =>
        {
          'code': code,
          'name': code,
          'debit': debit,
          'credit': credit,
          'closing_balance': closing,
        };

    test('it says whether it balances, at the top', () {
      expect(
          trialBalanceSpec([tb('1000', 500, 0, 500), tb('4000', 0, 500, -500)])
              .subtitle,
          'In balance');
    });

    test('and by how much when it does not', () {
      final spec = trialBalanceSpec([tb('1000', 500, 0, 500)]);
      expect(spec.subtitle, contains('Out of balance'));
      expect(spec.subtitle, contains('500'));
    });

    test('the account name is not treated as a number', () {
      // It is the second column, so "everything after the first is
      // numeric" right-aligned every account name against the far edge
      // of the page.
      final grid = trialBalanceSpec([tb('1000', 500, 0, 500)])
          .blocks
          .whereType<ReportGrid>()
          .single;
      expect(grid.isNumeric(0), isFalse, reason: 'code');
      expect(grid.isNumeric(1), isFalse, reason: 'account name');
      expect(grid.isNumeric(2), isTrue, reason: 'debit');
      expect(grid.isNumeric(3), isTrue, reason: 'credit');
      expect(grid.isNumeric(4), isTrue, reason: 'balance');
    });

    test('dormant accounts are dropped, and the totals follow', () {
      final spec = trialBalanceSpec([
        tb('1000', 500, 0, 500),
        tb('1100', 0, 0, 0),
        tb('4000', 0, 500, -500),
      ]);
      final grid = spec.blocks.whereType<ReportGrid>().single;
      expect(grid.rows, hasLength(2));
      expect((grid.total![2] as MoneyCell).value, 500);
      expect((grid.total![3] as MoneyCell).value, 500);
    });
  });

  group('SST summary', () {
    Map<String, dynamic> sst(String direction, double taxable, double tax) => {
          'direction': direction,
          'tax_type_code': 'SV',
          'tax_type_name': 'Service tax',
          'taxable_amount': taxable,
          'tax_amount': tax,
        };

    test('payable is output tax less input tax', () {
      final spec = sstSummarySpec(
          [sst('output', 10000, 800), sst('input', 5000, 300)], range);
      final h = spec.blocks.whereType<ReportHighlight>().single;
      expect(h.label, 'Tax payable');
      expect(h.value, 500);
    });

    test('more input than output is reclaimable, shown as a positive', () {
      // Printing "Tax payable -200" would be read as a payment due.
      final spec = sstSummarySpec(
          [sst('output', 1000, 100), sst('input', 5000, 300)], range);
      final h = spec.blocks.whereType<ReportHighlight>().single;
      expect(h.label, 'Tax reclaimable');
      expect(h.value, 200);
    });

    test('it does not present itself as the return', () {
      expect(sstSummarySpec([sst('output', 1, 1)], range).note,
          contains('SST-02'));
    });
  });

  group('cash flows', () {
    Map<String, dynamic> cf(String section, String label, double amount) =>
        {'section': section, 'label': label, 'amount': amount, 'sort_order': 10};

    final rows = [
      cf('operating', 'Profit for the period', 6500),
      cf('operating', 'Depreciation and amortisation', 500),
      cf('operating', 'Accounts Receivable', -4000),
      cf('operating', 'Accounts Payable', 1000),
      cf('investing', 'Property, Plant and Equipment', -5000),
      cf('reconciliation', 'Net movement in cash', -1000),
      cf('reconciliation', 'Cash and cash equivalents brought forward', 0),
      cf('reconciliation', 'Cash and cash equivalents carried forward', -1000),
    ];

    test('the sections total to the movement in cash', () {
      // The whole point of the statement. If the printed sections do not
      // come to the printed net movement, a reader adding them up gets a
      // different answer from the one at the foot of the page.
      final spec = cashFlowSpec(rows, range);
      final sections = spec.blocks.whereType<ReportSection>().toList();
      final total = sections.fold<double>(0, (s, x) => s + x.total);
      final net = spec.blocks.whereType<ReportHighlight>().single;
      expect(net.label, 'Net movement in cash');
      expect(total, net.value);
      expect(net.value, -1000);
    });

    test('a section with nothing in it does not print', () {
      // ReportView drops an empty section, so financing with no rows is
      // an absent heading rather than a heading with a zero under it.
      final spec = cashFlowSpec(rows, range);
      final financing = spec.blocks
          .whereType<ReportSection>()
          .firstWhere((s) => s.title == 'Financing activities');
      expect(financing.lines, isEmpty);
    });

    test('the cash brought and carried forward are shown, signed', () {
      final grid = cashFlowSpec(rows, range).blocks.whereType<ReportGrid>().single;
      expect(grid.rows, hasLength(2));
      // A bank overdraft is a negative, and printing 1,000 for -1,000
      // would read as money in the bank.
      expect((grid.rows[1][1] as MoneyCell).signed, isTrue);
      expect((grid.rows[1][1] as MoneyCell).value, -1000);
    });

    test('it says which method it used', () {
      expect(cashFlowSpec(rows, range).note, contains('indirect'));
    });
  });

  group('changes in equity', () {
    Map<String, dynamic> eq(String? code, String name, double opening,
            double movement) =>
        {
          'code': code,
          'name': name,
          'opening_balance': opening,
          'movement': movement,
          'closing_balance': opening + movement,
        };

    final rows = [
      eq('3100', 'Share Capital', 100000, 0),
      eq('3200', 'Retained Earnings', 20000, 0),
      eq(null, 'Profit for the financial period', 0, 30000),
    ];

    test('the total closes at the sum of the components', () {
      final grid =
          changesInEquitySpec(rows, range).blocks.whereType<ReportGrid>().single;
      expect((grid.total![4] as MoneyCell).value, 150000);
      expect((grid.total![2] as MoneyCell).value, 120000, reason: 'opening');
      expect((grid.total![3] as MoneyCell).value, 30000, reason: 'movement');
    });

    test('the result for the period is a component like any other', () {
      // It is not in retained earnings until the year is closed, and
      // leaving it off is what makes the statement disagree with the
      // balance sheet.
      final grid =
          changesInEquitySpec(rows, range).blocks.whereType<ReportGrid>().single;
      expect(grid.rows, hasLength(3));
      expect((grid.rows[2][1] as TextCell).text, 'Profit for the financial period');
      expect((grid.rows[2][0] as TextCell).text, '');
    });

    test('a deficit is shown as a deficit', () {
      final spec = changesInEquitySpec(
          [eq('3200', 'Retained Earnings', 5000, -9000)], range);
      final grid = spec.blocks.whereType<ReportGrid>().single;
      expect((grid.rows[0][4] as MoneyCell).value, -4000);
      expect((grid.rows[0][4] as MoneyCell).signed, isTrue);
    });
  });

  group('aged balances', () {
    final asAt = DateTime(2026, 3, 31);

    Map<String, dynamic> aged(
      String contact,
      String docNo,
      String bucket,
      double amount, {
      String kind = 'invoice',
      String? due = '2026-02-14',
      int days = 45,
    }) =>
        {
          'contact_id': contact.toLowerCase(),
          'contact_name': contact,
          'doc_kind': kind,
          'doc_no': docNo,
          'doc_date': '2026-01-15',
          'due_date': due,
          'currency': 'MYR',
          'outstanding': amount,
          'base_outstanding': amount,
          'days_overdue': days,
          'aging_bucket': bucket,
        };

    ReportGrid summaryOf(ReportSpec s) => s.blocks.whereType<ReportGrid>().first;

    test('one row per customer, whatever the ledger holds against them', () {
      final spec = agedBalanceSpec([
        aged('Steady Bhd', 'INV-1', '1_30', 1000),
        aged('Steady Bhd', 'INV-2', 'over_90', 400),
        aged('Late Bhd', 'INV-3', '31_60', 250),
      ], asAt, receivable: true);

      final grid = summaryOf(spec);
      expect(grid.rows, hasLength(2));
      expect(grid.headers.first, 'Customer');
      // Current, 1–30, 31–60, 61–90, Over 90, Total.
      expect(grid.headers, hasLength(7));
    });

    test('the buckets across a customer add up to that customer', () {
      final spec = agedBalanceSpec([
        aged('Steady Bhd', 'INV-1', '1_30', 1000),
        aged('Steady Bhd', 'INV-2', 'over_90', 400),
      ], asAt, receivable: true);

      final row = summaryOf(spec).rows.single;
      expect((row[2] as MoneyCell).value, 1000, reason: '1–30');
      expect((row[5] as MoneyCell).value, 400, reason: 'over 90');
      expect((row[6] as MoneyCell).value, 1400, reason: 'total');
    });

    test('and the columns down the page add up to the total', () {
      final spec = agedBalanceSpec([
        aged('Steady Bhd', 'INV-1', '1_30', 1000),
        aged('Late Bhd', 'INV-2', '1_30', 250),
        aged('Late Bhd', 'INV-3', 'current', 90),
      ], asAt, receivable: true);

      final total = summaryOf(spec).total!;
      expect((total[1] as MoneyCell).value, 90, reason: 'current');
      expect((total[2] as MoneyCell).value, 1250, reason: '1–30');
      expect((total[6] as MoneyCell).value, 1340, reason: 'grand total');
    });

    test('a credit carries its sign into the total', () {
      // Unapplied cash nets off what the customer owes. Summing the
      // magnitudes would show a customer in credit as a debtor.
      final spec = agedBalanceSpec([
        aged('Steady Bhd', 'INV-1', '1_30', 1000),
        aged('Steady Bhd', 'RCP-1', 'current', -1200,
            kind: 'receipt', due: null, days: 0),
      ], asAt, receivable: true);

      expect((summaryOf(spec).total!.last as MoneyCell).value, -200);
    });

    test('a credit is drawn as a negative rather than as a bare figure', () {
      // MoneyCell drops the sign unless it is asked to keep it, which on
      // this report turns money owed to a customer into money owed by
      // them.
      final spec = agedBalanceSpec([
        aged('Steady Bhd', 'CN-1', 'current', -300,
            kind: 'credit_note', due: null, days: 0),
      ], asAt, receivable: true);

      final cell = summaryOf(spec).rows.single.last as MoneyCell;
      expect(cell.signed, isTrue);
    });

    test('the detail names what a line is when it is not an invoice', () {
      final spec = agedBalanceSpec([
        aged('Steady Bhd', 'INV-1', '1_30', 1000),
        aged('Steady Bhd', 'RCP-1', 'current', -400,
            kind: 'receipt', due: null, days: 0),
      ], asAt, receivable: true);

      final detail = spec.blocks.whereType<ReportGrid>().last;
      expect((detail.rows[0][1] as TextCell).text, 'INV-1');
      expect((detail.rows[1][1] as TextCell).text, 'RCP-1 · receipt');
      // Cash on account has no due date, and printing one would age it
      // against a deadline nobody set.
      expect((detail.rows[1][3] as TextCell).text, '—');
    });

    test('the payables side says supplier, and says so in the title', () {
      final spec = agedBalanceSpec([aged('Parts Bhd', 'BILL-1', '1_30', 500)],
          asAt,
          receivable: false);
      expect(spec.title, 'Aged Payables');
      expect(summaryOf(spec).headers.first, 'Supplier');
      expect(spec.subtitle, contains('2026'));
    });

    test('it says the total is the control account', () {
      // The footing is the whole point of the report, and a reader who
      // does not know that will reconcile it against something else.
      expect(
        agedBalanceSpec([aged('Steady Bhd', 'INV-1', '1_30', 1)], asAt,
                receivable: true)
            .note,
        contains('control account'),
      );
    });
  });

  /// The deferred revenue schedule.
  ///
  /// Its note is the reason it is worth printing. A schedule that agrees
  /// with 2127 is a reconciliation; one that quietly disagrees is a
  /// listing that will be believed. So what is asserted is that it says
  /// which of the two it is, and never the wrong one.
  group('deferred revenue', () {
    Map<String, dynamic> line(
      String customer,
      String docNo,
      double deferred,
      double recognised,
      double cancelled,
      double ledger,
    ) => {
      'contact_name': customer,
      'doc_no': docNo,
      'doc_date': '2026-01-01',
      'description': 'Annual support',
      'service_start': '2026-01-01',
      'service_end': '2026-12-31',
      'deferred': deferred,
      'recognised': recognised,
      'cancelled': cancelled,
      'balance': deferred - recognised - cancelled,
      'ledger_balance': ledger,
    };

    final asAt = DateTime(2026, 6, 30);

    test('totals the balance column and leads with it', () {
      final spec = deferredRevenueSpec([
        line('Ali Sdn Bhd', 'INV-1', 1200, 600, 0, 1500),
        line('Baba Sdn Bhd', 'INV-2', 1800, 900, 0, 1500),
      ], asAt);

      final highlight =
          spec.blocks.whereType<ReportHighlight>().single;
      expect(highlight.value, 1500);
      expect(highlight.label, contains('30/06/2026'));

      final grid = spec.blocks.whereType<ReportGrid>().single;
      expect(grid.rows.length, 2);
      expect((grid.total!.last as MoneyCell).value, 1500);
    });

    test('says so when it agrees with 2127', () {
      final spec = deferredRevenueSpec([
        line('Ali Sdn Bhd', 'INV-1', 1200, 600, 0, 600),
      ], asAt);
      expect(spec.note, contains('Agrees with account 2127'));
    });

    // The failure this report exists to catch. A schedule of 600
    // against an account holding 900 is 300 nobody has explained, and
    // the note has to name the number rather than leaving it to be
    // worked out from two totals on different pages.
    test('and names the difference when it does not', () {
      final spec = deferredRevenueSpec([
        line('Ali Sdn Bhd', 'INV-1', 1200, 600, 0, 900),
      ], asAt);
      expect(spec.note, isNot(contains('Agrees')));
      expect(spec.note, contains('does not agree'));
      expect(spec.note, contains('900'));
      expect(spec.note, contains('300'));
    });

    // Rounding, not exactness: the schedule is rounded per period and
    // the ledger is the sum of those roundings, so insisting on
    // identical doubles would report a difference of nothing at all.
    test('a fraction of a sen is not a difference', () {
      final spec = deferredRevenueSpec([
        line('Ali Sdn Bhd', 'INV-1', 1200, 600, 0, 600.001),
      ], asAt);
      expect(spec.note, contains('Agrees with account 2127'));
    });

    test('a cancelled contract still adds across', () {
      final spec = deferredRevenueSpec([
        line('Ali Sdn Bhd', 'INV-1', 1200, 300, 400, 500),
      ], asAt);
      final grid = spec.blocks.whereType<ReportGrid>().single;
      expect((grid.total![3] as MoneyCell).value, 1200);
      expect((grid.total![4] as MoneyCell).value, 300);
      expect((grid.total![5] as MoneyCell).value, 400);
      expect((grid.total![6] as MoneyCell).value, 500);
    });

    test('nothing deferred is a zero balance, not a crash', () {
      final spec = deferredRevenueSpec(const [], asAt);
      expect(spec.blocks.whereType<ReportHighlight>().single.value, 0);
      expect(spec.blocks.whereType<ReportGrid>().single.rows, isEmpty);
    });
  });
}
