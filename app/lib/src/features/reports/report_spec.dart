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
  const ReportLine({required this.code, required this.name, required this.amount});

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
  const ReportHighlight(
      {required this.label, required this.value, this.emphasise = false});

  final String label;
  final double value;
  final bool emphasise;
}

// ---------------------------------------------------------------------
// The four reports, derived from the rows the database returns.
// ---------------------------------------------------------------------

ReportSpec profitLossSpec(List<Map<String, dynamic>> rows, DateTimeRange range) {
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
  final expenses = lines((r) =>
      r['account_type'] == 'expense' && r['account_subtype'] != 'cost_of_sales');

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
          emphasise: true),
    ],
  );
}

ReportSpec balanceSheetSpec(List<Map<String, dynamic>> rows, DateTime asAt) {
  List<ReportLine> lines(String type) => [
        for (final r in rows.where((r) =>
            r['account_type'] == type && Fmt.toDouble(r['balance']) != 0))
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
    note: 'This should be zero once the year-end profit is transferred to '
        'retained earnings.',
  );
}

ReportSpec trialBalanceSpec(List<Map<String, dynamic>> rows) {
  // Accounts that never moved and hold nothing are noise on a printed
  // page, so they are left out here rather than in the caller.
  final active = rows
      .where((r) =>
          Fmt.toDouble(r['debit']) != 0 ||
          Fmt.toDouble(r['credit']) != 0 ||
          Fmt.toDouble(r['closing_balance']) != 0)
      .toList();

  final totalDebit =
      active.fold<double>(0, (s, r) => s + Fmt.toDouble(r['debit']));
  final totalCredit =
      active.fold<double>(0, (s, r) => s + Fmt.toDouble(r['credit']));

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

ReportSpec sstSummarySpec(
    List<Map<String, dynamic>> rows, DateTimeRange range) {
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
    subtitle: 'Supporting figures for the SST-02 return · '
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
    note: 'Prepared from posted documents. Check it against your tax code '
        'mapping before filing the SST-02.',
  );
}
