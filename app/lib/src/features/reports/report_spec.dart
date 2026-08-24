import 'package:flutter/material.dart' show DateTimeRange;

import '../../core/format.dart';

/// What a report *is*, separately from how it is drawn.
///
/// The screen and the PDF both render one of these. That is the whole
/// point of the file: a printed profit and loss that disagrees with the
/// one on screen is worse than having no PDF at all, and the way that
/// happens is two copies of the same filter drifting apart. The
/// arithmetic lives here, once, where a test can reach it without a
/// widget tree.
class ReportSpec {
  const ReportSpec({
    required this.title,
    required this.subtitle,
    required this.blocks,
    this.note,
  });

  final String title;

  /// The period or the as-at date. A financial report without one is not
  /// a report, so this is required rather than nullable.
  final String subtitle;

  final List<ReportBlock> blocks;

  /// A caveat printed under the report — the balance-sheet check uses it.
  final String? note;
}

sealed class ReportBlock {
  const ReportBlock();
}

/// A named list of accounts with a subtotal: the shape of every section
/// of a profit and loss or a balance sheet.
final class ReportSection extends ReportBlock {
  const ReportSection({required this.title, required this.lines});

  final String title;
  final List<ReportLine> lines;

  double get total => lines.fold(0, (sum, l) => sum + l.amount);
}

class ReportLine {
  const ReportLine({
    required this.code,
    required this.name,
    required this.amount,
  });

  final String code;
  final String name;
  final double amount;
}

/// A columnar table: the trial balance and the SST breakdown.
final class ReportGrid extends ReportBlock {
  const ReportGrid({
    required this.title,
    required this.headers,
    required this.rows,
    this.total,
  });

  final String? title;
  final List<String> headers;
  final List<List<Cell>> rows;

  /// A bold closing row, or null when the table does not foot to
  /// anything — the SST breakdown ends in a highlight instead.
  final List<Cell>? total;

  /// Whether a column holds money, and so should be right-aligned.
  ///
  /// Derived from the cells rather than declared, because "everything
  /// after the first column is a number" is wrong the moment a table has
  /// two label columns — which the trial balance does, and which pushed
  /// the account names to the right-hand edge until this existed. A
  /// column counts as numeric only if every row agrees.
  bool isNumeric(int column) {
    if (rows.isEmpty) return column > 0;
    return rows.every((r) => column < r.length && r[column] is MoneyCell);
  }
}

sealed class Cell {
  const Cell();
}

final class TextCell extends Cell {
  const TextCell(this.text);
  final String text;
}

final class MoneyCell extends Cell {
  const MoneyCell(this.value, {this.signed = false});

  final double value;

  /// Show a negative as negative rather than as a bare magnitude. A
  /// closing balance needs it; a debit column does not.
  final bool signed;
}

/// A figure that is the answer rather than a component: gross profit,
/// net profit, tax payable.
final class ReportHighlight extends ReportBlock {
  const ReportHighlight({
    required this.label,
    required this.value,
    this.emphasise = false,
  });

  final String label;
  final double value;
  final bool emphasise;
}

// ---------------------------------------------------------------------
// The four reports, derived from the rows the database returns.
// ---------------------------------------------------------------------

ReportSpec profitLossSpec(
  List<Map<String, dynamic>> rows,
  DateTimeRange range,
) {
  List<ReportLine> lines(bool Function(Map<String, dynamic>) where) => [
    for (final r in rows.where(where))
      ReportLine(
        code: r['code']?.toString() ?? '',
        name: r['name']?.toString() ?? '',
        amount: Fmt.toDouble(r['amount']),
      ),
  ];

  final revenue = lines((r) => r['account_type'] == 'revenue');
  final cogs = lines((r) => r['account_subtype'] == 'cost_of_sales');
  final expenses = lines(
    (r) =>
        r['account_type'] == 'expense' &&
        r['account_subtype'] != 'cost_of_sales',
  );

  double sum(List<ReportLine> l) => l.fold(0, (s, x) => s + x.amount);
  final grossProfit = sum(revenue) - sum(cogs);

  return ReportSpec(
    title: 'Profit & Loss',
    subtitle: '${Fmt.longDate(range.start)} to ${Fmt.longDate(range.end)}',
    blocks: [
      ReportSection(title: 'Revenue', lines: revenue),
      ReportSection(title: 'Cost of Sales', lines: cogs),
      ReportHighlight(label: 'Gross profit', value: grossProfit),
      ReportSection(title: 'Expenses', lines: expenses),
      ReportHighlight(
        label: 'Net profit',
        value: grossProfit - sum(expenses),
        emphasise: true,
      ),
    ],
  );
}

ReportSpec balanceSheetSpec(List<Map<String, dynamic>> rows, DateTime asAt) {
  List<ReportLine> lines(String type) => [
    for (final r in rows.where(
      (r) => r['account_type'] == type && Fmt.toDouble(r['balance']) != 0,
    ))
      ReportLine(
        code: r['code']?.toString() ?? '',
        name: r['name']?.toString() ?? '',
        amount: Fmt.toDouble(r['balance']),
      ),
  ];

  final assets = lines('asset');
  final liabilities = lines('liability');
  final equity = lines('equity');
  double sum(List<ReportLine> l) => l.fold(0, (s, x) => s + x.amount);

  return ReportSpec(
    title: 'Balance Sheet',
    subtitle: 'As at ${Fmt.longDate(asAt)}',
    blocks: [
      ReportSection(title: 'Assets', lines: assets),
      ReportSection(title: 'Liabilities', lines: liabilities),
      ReportSection(title: 'Equity', lines: equity),
      ReportHighlight(
        label: 'Assets less liabilities and equity',
        value: sum(assets) - sum(liabilities) - sum(equity),
        emphasise: true,
      ),
    ],
    note:
        'This should be zero once the year-end profit is transferred to '
        'retained earnings.',
  );
}

ReportSpec trialBalanceSpec(List<Map<String, dynamic>> rows) {
  // Accounts that never moved and hold nothing are noise on a printed
  // page, so they are left out here rather than in the caller.
  final active = rows
      .where(
        (r) =>
            Fmt.toDouble(r['debit']) != 0 ||
            Fmt.toDouble(r['credit']) != 0 ||
            Fmt.toDouble(r['closing_balance']) != 0,
      )
      .toList();

  final totalDebit = active.fold<double>(
    0,
    (s, r) => s + Fmt.toDouble(r['debit']),
  );
  final totalCredit = active.fold<double>(
    0,
    (s, r) => s + Fmt.toDouble(r['credit']),
  );

  return ReportSpec(
    title: 'Trial Balance',
    // Whether it balances is the first thing anyone checks, so it is
    // stated at the top rather than left to be worked out from the
    // bottom two figures.
    subtitle: totalDebit == totalCredit
        ? 'In balance'
        : 'Out of balance by ${Fmt.money(totalDebit - totalCredit)}',
    blocks: [
      ReportGrid(
        title: null,
        headers: const ['Code', 'Account', 'Debit', 'Credit', 'Balance'],
        rows: [
          for (final r in active)
            [
              TextCell(r['code']?.toString() ?? ''),
              TextCell(r['name']?.toString() ?? ''),
              MoneyCell(Fmt.toDouble(r['debit'])),
              MoneyCell(Fmt.toDouble(r['credit'])),
              MoneyCell(Fmt.toDouble(r['closing_balance']), signed: true),
            ],
        ],
        total: [
          const TextCell(''),
          const TextCell('Total'),
          MoneyCell(totalDebit),
          MoneyCell(totalCredit),
          const TextCell(''),
        ],
      ),
    ],
  );
}

/// The statement of cash flows, indirect method.
///
/// The reconciliation at the foot is the point of the whole thing: the
/// three sections have to come to the movement in the bank, and the
/// bank figures are read straight from the cash accounts. A cash flow
/// statement that does not tie is worse than none, because somebody
/// will believe it.
ReportSpec cashFlowSpec(List<Map<String, dynamic>> rows, DateTimeRange range) {
  List<ReportLine> linesOf(String section) => [
    for (final r in rows.where((r) => r['section'] == section))
      ReportLine(
        code: '',
        name: r['label']?.toString() ?? '',
        amount: Fmt.toDouble(r['amount']),
      ),
  ];

  double reconciliation(String label) => Fmt.toDouble(
    rows.firstWhere(
      (r) => r['label'] == label,
      orElse: () => const {},
    )['amount'],
  );

  return ReportSpec(
    title: 'Statement of Cash Flows',
    subtitle: '${Fmt.longDate(range.start)} to ${Fmt.longDate(range.end)}',
    blocks: [
      ReportSection(title: 'Operating activities', lines: linesOf('operating')),
      ReportSection(title: 'Investing activities', lines: linesOf('investing')),
      ReportSection(title: 'Financing activities', lines: linesOf('financing')),
      ReportHighlight(
        label: 'Net movement in cash',
        value: reconciliation('Net movement in cash'),
        emphasise: true,
      ),
      ReportGrid(
        title: 'Cash and cash equivalents',
        headers: const ['', 'Amount'],
        rows: [
          for (final label in const [
            'Cash and cash equivalents brought forward',
            'Cash and cash equivalents carried forward',
          ])
            [TextCell(label), MoneyCell(reconciliation(label), signed: true)],
        ],
      ),
    ],
    note:
        'Prepared by the indirect method. Depreciation is added back in '
        'operating activities, so the charge and the accumulated '
        'depreciation it credits cancel.',
  );
}

/// The statement of changes in equity.
///
/// Components down the page rather than across it: with a handful of
/// them the transpose reads the same and fits a phone, which the
/// conventional four-column layout does not.
ReportSpec changesInEquitySpec(
  List<Map<String, dynamic>> rows,
  DateTimeRange range,
) {
  double column(String key) =>
      rows.fold<double>(0, (s, r) => s + Fmt.toDouble(r[key]));

  return ReportSpec(
    title: 'Statement of Changes in Equity',
    subtitle: '${Fmt.longDate(range.start)} to ${Fmt.longDate(range.end)}',
    blocks: [
      ReportGrid(
        title: null,
        headers: const ['Code', 'Component', 'Opening', 'Movement', 'Closing'],
        rows: [
          for (final r in rows)
            [
              TextCell(r['code']?.toString() ?? ''),
              TextCell(r['name']?.toString() ?? ''),
              MoneyCell(Fmt.toDouble(r['opening_balance']), signed: true),
              MoneyCell(Fmt.toDouble(r['movement']), signed: true),
              MoneyCell(Fmt.toDouble(r['closing_balance']), signed: true),
            ],
        ],
        total: [
          const TextCell(''),
          const TextCell('Total equity'),
          MoneyCell(column('opening_balance'), signed: true),
          MoneyCell(column('movement'), signed: true),
          MoneyCell(column('closing_balance'), signed: true),
        ],
      ),
    ],
    note:
        'The result for the period is shown on its own line until the '
        'year is closed, because that is where it is: in the profit and '
        'loss, not yet in retained earnings. Closing equity equals net '
        'assets on the balance sheet either way.',
  );
}

/// The five columns, in the order they are read across a page.
const _agingBuckets = <String, String>{
  'current': 'Current',
  '1_30': '1–30',
  '31_60': '31–60',
  '61_90': '61–90',
  'over_90': 'Over 90',
};

/// What a line is, when it is not simply an invoice or a bill. Left
/// blank for those two so the common row stays uncluttered.
String _agedKind(String kind) => switch (kind) {
  'invoice' || 'bill' => '',
  'credit_note' || 'purchase_credit_note' => 'credit note',
  'debit_note' || 'purchase_debit_note' => 'debit note',
  'refund_note' => 'refund note',
  'receipt' => 'receipt',
  'payment' => 'payment',
  _ => kind.replaceAll('_', ' '),
};

/// An aged trial balance: who owes what, and for how long.
///
/// Two blocks, because they answer different questions. The summary is
/// the page that gets printed and taken to a meeting; the detail is the
/// page somebody works from when they pick up the phone.
///
/// Amounts are the base-currency ones the ledger carries, so the report
/// foots to the receivable or payable control account. That is the point
/// of it: an aged listing that does not agree with the nominal gets
/// reconciled by hand every month until nobody believes either number.
ReportSpec agedBalanceSpec(
  List<Map<String, dynamic>> rows,
  DateTime asAt, {
  required bool receivable,
}) {
  // Rows arrive ordered by name, so insertion order is display order.
  final buckets = <String, Map<String, double>>{};
  final names = <String, String>{};

  for (final r in rows) {
    final key = r['contact_id']?.toString() ?? '';
    names[key] = r['contact_name']?.toString() ?? '—';
    final bucket = r['aging_bucket']?.toString() ?? 'current';
    final amount = Fmt.toDouble(r['base_outstanding']);
    final row = buckets.putIfAbsent(key, () => <String, double>{});
    row[bucket] = (row[bucket] ?? 0) + amount;
  }

  double columnTotal(String bucket) =>
      buckets.values.fold(0, (s, r) => s + (r[bucket] ?? 0));
  double rowTotal(Map<String, double> r) => r.values.fold(0, (s, v) => s + v);

  final grand = buckets.values.fold<double>(0, (s, r) => s + rowTotal(r));

  final summary = ReportGrid(
    title: null,
    headers: [
      receivable ? 'Customer' : 'Supplier',
      ..._agingBuckets.values,
      'Total',
    ],
    rows: [
      for (final entry in buckets.entries)
        [
          TextCell(names[entry.key] ?? '—'),
          for (final bucket in _agingBuckets.keys)
            MoneyCell(entry.value[bucket] ?? 0, signed: true),
          MoneyCell(rowTotal(entry.value), signed: true),
        ],
    ],
    total: [
      const TextCell('Total'),
      for (final bucket in _agingBuckets.keys)
        MoneyCell(columnTotal(bucket), signed: true),
      MoneyCell(grand, signed: true),
    ],
  );

  final detail = ReportGrid(
    title: 'Detail',
    headers: const ['Contact', 'Document', 'Date', 'Due', 'Days', 'Amount'],
    rows: [
      for (final r in rows)
        [
          TextCell(r['contact_name']?.toString() ?? '—'),
          TextCell(
            [
              r['doc_no']?.toString() ?? '',
              _agedKind(r['doc_kind']?.toString() ?? ''),
            ].where((s) => s.isNotEmpty).join(' · '),
          ),
          TextCell(Fmt.date(Fmt.parseDate(r['doc_date']))),
          // Cash on account and credit notes have no due date, and an
          // invented one would age them against a deadline nobody set.
          TextCell(
            r['due_date'] == null
                ? '—'
                : Fmt.date(Fmt.parseDate(r['due_date'])),
          ),
          TextCell(
            Fmt.toInt(r['days_overdue']) == 0
                ? '—'
                : '${Fmt.toInt(r['days_overdue'])}',
          ),
          MoneyCell(Fmt.toDouble(r['base_outstanding']), signed: true),
        ],
    ],
  );

  return ReportSpec(
    title: receivable ? 'Aged Receivables' : 'Aged Payables',
    subtitle: 'As at ${Fmt.longDate(asAt)}',
    blocks: [summary, detail],
    note: receivable
        ? 'Includes credit notes and receipts not yet applied, shown as '
              'negatives, so the total agrees with the receivables control '
              'account at this date. Amounts are in the base currency at the '
              'rate each document was posted at.'
        : 'Includes credit notes and payments not yet applied, shown as '
              'negatives, so the total agrees with the payables control '
              'account at this date. Amounts are in the base currency at the '
              'rate each document was posted at.',
  );
}

ReportSpec sstSummarySpec(
  List<Map<String, dynamic>> rows,
  DateTimeRange range,
) {
  ReportGrid grid(String title, String direction) {
    final of = rows.where((r) => r['direction'] == direction).toList();
    return ReportGrid(
      title: title,
      headers: const ['Tax type', 'Taxable', 'Tax'],
      rows: [
        for (final r in of)
          [
            TextCell('${r['tax_type_code']} — ${r['tax_type_name']}'),
            MoneyCell(Fmt.toDouble(r['taxable_amount'])),
            MoneyCell(Fmt.toDouble(r['tax_amount'])),
          ],
      ],
    );
  }

  double tax(String direction) => rows
      .where((r) => r['direction'] == direction)
      .fold<double>(0, (s, r) => s + Fmt.toDouble(r['tax_amount']));

  final payable = tax('output') - tax('input');

  return ReportSpec(
    title: 'SST Summary',
    subtitle:
        'Supporting figures for the SST-02 return · '
        '${Fmt.longDate(range.start)} to ${Fmt.longDate(range.end)}',
    blocks: [
      grid('Output tax (sales)', 'output'),
      grid('Input tax (purchases)', 'input'),
      ReportHighlight(
        label: payable >= 0 ? 'Tax payable' : 'Tax reclaimable',
        value: payable.abs(),
        emphasise: true,
      ),
    ],
    // The figures are a starting point for the return, not the return.
    note:
        'Prepared from posted documents. Check it against your tax code '
        'mapping before filing the SST-02.',
  );
}

// =====================================================================
// Across a company group
// =====================================================================

/// The combined trial balance, and the sentence that keeps it honest.
///
/// The note is not decoration. This adds several companies together
/// without eliminating anything between them, so an inter-company
/// invoice is counted as revenue in one and as a cost in another, and
/// the same debt appears as a receivable in one and a payable in the
/// other. Somebody reading a total headed "group" will assume it is a
/// consolidation unless told otherwise, and on a printed page there is
/// nobody to ask.
ReportSpec groupTrialBalanceSpec(
  List<Map<String, dynamic>> rows,
  DateTimeRange range, {
  required int companies,
}) {
  final active = rows
      .where(
        (r) =>
            Fmt.toDouble(r['debit']) != 0 ||
            Fmt.toDouble(r['credit']) != 0 ||
            Fmt.toDouble(r['closing_balance']) != 0,
      )
      .toList();

  final totalDebit = active.fold<double>(
    0,
    (s, r) => s + Fmt.toDouble(r['debit']),
  );
  final totalCredit = active.fold<double>(
    0,
    (s, r) => s + Fmt.toDouble(r['credit']),
  );

  return ReportSpec(
    title: 'Combined Trial Balance',
    subtitle:
        '$companies ${companies == 1 ? 'company' : 'companies'} · '
        '${Fmt.date(range.start)} – ${Fmt.date(range.end)}'
        '${totalDebit == totalCredit ? ' · In balance' : ' · Out of balance by '
                  '${Fmt.money(totalDebit - totalCredit)}'}',
    note:
        'Combined, not consolidated. Nothing between the companies has '
        'been eliminated: an invoice from one to another is counted as '
        'revenue in the first and as a cost in the second, and the same '
        'debt appears on both sides. The Inter-company report shows what '
        'a consolidation would remove.',
    blocks: [
      ReportGrid(
        title: null,
        // "In" is how many of the companies hold that account at all,
        // which is the first thing to look at when a figure surprises
        // somebody — a balance carried by one company out of four reads
        // very differently from one carried by all four.
        headers: const ['Code', 'Account', 'In', 'Debit', 'Credit', 'Balance'],
        rows: [
          for (final r in active)
            [
              TextCell(r['code']?.toString() ?? ''),
              TextCell(r['name']?.toString() ?? ''),
              TextCell('${r['companies'] ?? ''}'),
              MoneyCell(Fmt.toDouble(r['debit'])),
              MoneyCell(Fmt.toDouble(r['credit'])),
              MoneyCell(Fmt.toDouble(r['closing_balance']), signed: true),
            ],
        ],
        total: [
          const TextCell(''),
          const TextCell('Total'),
          const TextCell(''),
          MoneyCell(totalDebit),
          MoneyCell(totalCredit),
          const TextCell(''),
        ],
      ),
    ],
  );
}

/// What a consolidation would have to eliminate.
///
/// Both sides are listed rather than netted. When they disagree — and
/// they routinely do, because one company has posted the invoice and
/// the other has not yet received it — the difference is the thing
/// worth looking at, and netting hides it.
ReportSpec intercompanySpec(
  List<Map<String, dynamic>> rows,
  DateTimeRange range,
) {
  final receivable = rows.fold<double>(
    0,
    (s, r) => s + Fmt.toDouble(r['receivable']),
  );
  final payable = rows.fold<double>(
    0,
    (s, r) => s + Fmt.toDouble(r['payable']),
  );
  final revenue = rows.fold<double>(
    0,
    (s, r) => s + Fmt.toDouble(r['revenue']),
  );

  return ReportSpec(
    title: 'Inter-company',
    subtitle: '${Fmt.date(range.start)} – ${Fmt.date(range.end)}',
    note: receivable == payable
        ? null
        : 'The two sides do not agree by ${Fmt.money(receivable - payable)}. '
              'That is usually a document posted in one company and not yet '
              'in the other, and it has to be resolved before these figures '
              'can be eliminated.',
    blocks: [
      ReportGrid(
        title: null,
        headers: const [
          'Company',
          'Counterparty',
          'Receivable',
          'Payable',
          'Revenue',
          'Cost',
        ],
        rows: [
          for (final r in rows)
            [
              TextCell(r['from_org']?.toString() ?? ''),
              TextCell(r['to_org']?.toString() ?? ''),
              MoneyCell(Fmt.toDouble(r['receivable'])),
              MoneyCell(Fmt.toDouble(r['payable'])),
              MoneyCell(Fmt.toDouble(r['revenue'])),
              MoneyCell(Fmt.toDouble(r['expense'])),
            ],
        ],
        total: [
          const TextCell(''),
          const TextCell('Total'),
          MoneyCell(receivable),
          MoneyCell(payable),
          MoneyCell(revenue),
          MoneyCell(
            rows.fold<double>(0, (s, r) => s + Fmt.toDouble(r['expense'])),
          ),
        ],
      ),
    ],
  );
}

/// The combined trial balance with inter-company trading taken out.
///
/// Three money columns rather than one, because the interesting thing is
/// not the consolidated figure on its own — it is the pair. An
/// accountant reading a consolidation wants to see what was there and
/// what came off, and a single column would hide the second.
ReportSpec consolidatedSpec(
  List<Map<String, dynamic>> rows,
  DateTimeRange range, {
  required int companies,
  required int unreconciled,
}) {
  final active = rows
      .where(
        (r) =>
            Fmt.toDouble(r['combined_balance']) != 0 ||
            Fmt.toDouble(r['elimination']) != 0,
      )
      .toList();

  final eliminated = active.fold<double>(
    0,
    (s, r) => s + Fmt.toDouble(r['elimination']).abs(),
  );

  return ReportSpec(
    title: 'Consolidated Trial Balance',
    subtitle:
        '$companies ${companies == 1 ? 'company' : 'companies'} · '
        '${Fmt.date(range.start)} – ${Fmt.date(range.end)}',
    note: unreconciled == 0
        ? 'Inter-company balances and trading have been eliminated. Still '
              'not adjusted: unrealised profit in stock bought from another '
              'company in the group, which needs lineage this system does '
              'not record.'
        : '$unreconciled inter-company ${unreconciled == 1 ? 'pair does' : 'pairs do'} '
              'not agree, and nothing has been eliminated for '
              '${unreconciled == 1 ? 'it' : 'them'}. Eliminating the smaller '
              'side would balance and would bury the difference inside these '
              'figures. Reconcile them first — the Inter-company tab lists '
              'which.',
    blocks: [
      ReportGrid(
        title: null,
        headers: const [
          'Code',
          'Account',
          'Combined',
          'Eliminated',
          'Consolidated',
        ],
        rows: [
          for (final r in active)
            [
              TextCell(r['code']?.toString() ?? ''),
              TextCell(r['name']?.toString() ?? ''),
              MoneyCell(Fmt.toDouble(r['combined_balance']), signed: true),
              MoneyCell(Fmt.toDouble(r['elimination']), signed: true),
              MoneyCell(Fmt.toDouble(r['consolidated_balance']), signed: true),
            ],
        ],
        total: [
          const TextCell(''),
          TextCell('Eliminated ${Fmt.money(eliminated / 2)} in total'),
          const TextCell(''),
          const TextCell(''),
          const TextCell(''),
        ],
      ),
    ],
  );
}

/// What is sitting in deferred revenue, and which invoice lines it is.
///
/// The report an auditor asks for at a year end: 2127 says a number,
/// show me what that number is made of.
///
/// Its note is the only thing that makes it worth printing. A schedule
/// of contracts is a listing; a schedule that says out loud whether it
/// agrees with the account it is supposed to support is a reconciliation,
/// and a difference found here is found before the audit rather than
/// during it.
ReportSpec deferredRevenueSpec(
  List<Map<String, dynamic>> rows,
  DateTime asAt,
) {
  double column(String key) =>
      rows.fold(0, (s, r) => s + Fmt.toDouble(r[key]));

  final balance = column('balance');

  // Repeated on every row by `report_deferred_revenue`, deliberately, so
  // the schedule and the account are read from one moment rather than
  // two. With no rows there is nothing to reconcile and nothing to say.
  final ledger =
      rows.isEmpty ? 0.0 : Fmt.toDouble(rows.first['ledger_balance']);
  final difference = balance - ledger;

  return ReportSpec(
    title: 'Deferred Revenue',
    subtitle: 'As at ${Fmt.date(asAt)}',
    note: difference.abs() < 0.005
        ? 'Agrees with account 2127 at this date. Periods that have '
              'matured but have not been released are still counted as '
              'deferred here, because the ledger still holds them — run '
              'the release in Settings to move them to income.'
        : 'This does not agree with account 2127, which holds '
              '${Fmt.money(ledger)} at this date — a difference of '
              '${Fmt.money(difference.abs())}. The usual cause is a '
              'journal posted to 2127 by hand, which has no schedule '
              'behind it and so cannot appear above. Check the general '
              'ledger for that account before relying on either figure.',
    blocks: [
      ReportGrid(
        title: null,
        headers: const [
          'Customer',
          'Invoice',
          'Earned over',
          'Deferred',
          'Recognised',
          'Cancelled',
          'Balance',
        ],
        rows: [
          for (final r in rows)
            [
              TextCell(r['contact_name']?.toString() ?? '—'),
              TextCell(
                [
                  r['doc_no']?.toString() ?? '',
                  r['description']?.toString() ?? '',
                ].where((s) => s.isNotEmpty).join(' · '),
              ),
              TextCell(_servicePeriod(r)),
              MoneyCell(Fmt.toDouble(r['deferred'])),
              MoneyCell(Fmt.toDouble(r['recognised'])),
              MoneyCell(Fmt.toDouble(r['cancelled'])),
              MoneyCell(Fmt.toDouble(r['balance'])),
            ],
        ],
        total: [
          const TextCell('Total'),
          const TextCell(''),
          const TextCell(''),
          MoneyCell(column('deferred')),
          MoneyCell(column('recognised')),
          MoneyCell(column('cancelled')),
          MoneyCell(balance),
        ],
      ),
      ReportHighlight(
        label: 'Deferred revenue at ${Fmt.date(asAt)}',
        value: balance,
        emphasise: true,
      ),
    ],
  );
}

/// The period a deferred line is earned over, as it reads in a cell.
///
/// Both dates are always present — `sales_document_lines` has a check
/// constraint refusing one without the other — so a row missing either
/// is a row that should not have been scheduled, and an em dash says so
/// rather than printing half a period.
String _servicePeriod(Map<String, dynamic> r) {
  final from = Fmt.parseDate(r['service_start']);
  final to = Fmt.parseDate(r['service_end']);
  if (from == null || to == null) return '—';
  return '${Fmt.date(from)} – ${Fmt.date(to)}';
}
