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
}
