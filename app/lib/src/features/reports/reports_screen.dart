import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';

class ReportsScreen extends ConsumerStatefulWidget {
  const ReportsScreen({super.key});

  @override
  ConsumerState<ReportsScreen> createState() => _ReportsScreenState();
}

class _ReportsScreenState extends ConsumerState<ReportsScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;

  DateTimeRange _range = DateTimeRange(
    start: DateTime(DateTime.now().year, 1, 1),
    end: DateTime.now(),
  );

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 4, vsync: this);
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Reports'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: OutlinedButton.icon(
              onPressed: () async {
                final picked = await showDateRangePicker(
                  context: context,
                  firstDate: DateTime(2000),
                  lastDate: DateTime(2100),
                  initialDateRange: _range,
                );
                if (picked != null) setState(() => _range = picked);
              },
              icon: const Icon(Icons.date_range, size: 18),
              label: Text(
                '${Fmt.date(_range.start)} – ${Fmt.date(_range.end)}',
              ),
            ),
          ),
        ],
        bottom: TabBar(
          controller: _tabs,
          isScrollable: true,
          tabAlignment: TabAlignment.start,
          tabs: const [
            Tab(text: 'Profit & Loss'),
            Tab(text: 'Balance Sheet'),
            Tab(text: 'Trial Balance'),
            Tab(text: 'SST Summary'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabs,
        children: [
          _ProfitLoss(range: _range),
          _BalanceSheet(asAt: _range.end),
          const _TrialBalance(),
          _SstSummary(range: _range),
        ],
      ),
    );
  }
}

/// Groups report rows under a heading with a subtotal.
class _ReportGroup extends StatelessWidget {
  const _ReportGroup({
    required this.title,
    required this.rows,
    required this.amountKey,
  });

  final String title;
  final List<Map<String, dynamic>> rows;
  final String amountKey;

  @override
  Widget build(BuildContext context) {
    if (rows.isEmpty) return const SizedBox.shrink();

    final total =
        rows.fold<double>(0, (sum, r) => sum + Fmt.toDouble(r[amountKey]));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(0, 20, 0, 8),
          child: Text(
            title.toUpperCase(),
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.6,
                ),
          ),
        ),
        for (final r in rows)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 5),
            child: Row(
              children: [
                SizedBox(
                  width: 72,
                  child: Text(
                    r['code']?.toString() ?? '',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
                Expanded(child: Text(r['name']?.toString() ?? '')),
                Money(Fmt.toDouble(r[amountKey])),
              ],
            ),
          ),
        const Divider(height: 20),
        Row(
          children: [
            const SizedBox(width: 72),
            Expanded(
              child: Text(
                'Total $title',
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
            Money(total, bold: true),
          ],
        ),
      ],
    );
  }
}

class _ProfitLoss extends ConsumerWidget {
  const _ProfitLoss({required this.range});

  final DateTimeRange range;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(_profitLossProvider(range));

    return AsyncView(
      value: data,
      onRetry: () => ref.invalidate(_profitLossProvider),
      builder: (rows) {
        if (rows.isEmpty) {
          return const EmptyState(
            icon: Icons.summarize_outlined,
            title: 'Nothing posted in this period',
            message: 'Post invoices and bills to populate the P&L.',
          );
        }

        final revenue =
            rows.where((r) => r['account_type'] == 'revenue').toList();
        final cogs = rows
            .where((r) => r['account_subtype'] == 'cost_of_sales')
            .toList();
        final expenses = rows
            .where((r) =>
                r['account_type'] == 'expense' &&
                r['account_subtype'] != 'cost_of_sales')
            .toList();

        double sum(List<Map<String, dynamic>> list) =>
            list.fold(0, (s, r) => s + Fmt.toDouble(r['amount']));

        final grossProfit = sum(revenue) - sum(cogs);
        final netProfit = grossProfit - sum(expenses);

        return SingleChildScrollView(
          child: PageBody(
            maxWidth: 860,
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SectionHeader(
                      'Profit & Loss',
                      subtitle:
                          '${Fmt.longDate(range.start)} to ${Fmt.longDate(range.end)}',
                    ),
                    _ReportGroup(
                        title: 'Revenue', rows: revenue, amountKey: 'amount'),
                    _ReportGroup(
                        title: 'Cost of Sales', rows: cogs, amountKey: 'amount'),
                    _Highlight(label: 'Gross profit', value: grossProfit),
                    _ReportGroup(
                        title: 'Expenses', rows: expenses, amountKey: 'amount'),
                    const SizedBox(height: 8),
                    _Highlight(
                      label: 'Net profit',
                      value: netProfit,
                      emphasise: true,
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _Highlight extends StatelessWidget {
  const _Highlight({
    required this.label,
    required this.value,
    this.emphasise = false,
  });

  final String label;
  final double value;
  final bool emphasise;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(top: 16),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: (value >= 0 ? AppTheme.success : AppTheme.danger)
            .withValues(alpha: emphasise ? 0.12 : 0.06),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                fontWeight: FontWeight.w700,
                fontSize: emphasise ? 16 : 14,
              ),
            ),
          ),
          Money(
            value,
            bold: true,
            colorNegative: true,
            style: emphasise
                ? Theme.of(context).textTheme.titleLarge
                : Theme.of(context).textTheme.titleMedium,
          ),
        ],
      ),
    );
  }
}

class _BalanceSheet extends ConsumerWidget {
  const _BalanceSheet({required this.asAt});

  final DateTime asAt;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(_balanceSheetProvider(asAt));

    return AsyncView(
      value: data,
      onRetry: () => ref.invalidate(_balanceSheetProvider),
      builder: (rows) {
        final assets = rows
            .where((r) => r['account_type'] == 'asset')
            .where((r) => Fmt.toDouble(r['balance']) != 0)
            .toList();
        final liabilities = rows
            .where((r) => r['account_type'] == 'liability')
            .where((r) => Fmt.toDouble(r['balance']) != 0)
            .toList();
        final equity = rows
            .where((r) => r['account_type'] == 'equity')
            .where((r) => Fmt.toDouble(r['balance']) != 0)
            .toList();

        if (assets.isEmpty && liabilities.isEmpty && equity.isEmpty) {
          return const EmptyState(
            icon: Icons.balance,
            title: 'Nothing on the balance sheet yet',
            message: 'Post transactions to build up your position.',
          );
        }

        double sum(List<Map<String, dynamic>> l) =>
            l.fold(0, (s, r) => s + Fmt.toDouble(r['balance']));

        return SingleChildScrollView(
          child: PageBody(
            maxWidth: 860,
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SectionHeader(
                      'Balance Sheet',
                      subtitle: 'As at ${Fmt.longDate(asAt)}',
                    ),
                    _ReportGroup(
                        title: 'Assets', rows: assets, amountKey: 'balance'),
                    _ReportGroup(
                        title: 'Liabilities',
                        rows: liabilities,
                        amountKey: 'balance'),
                    _ReportGroup(
                        title: 'Equity', rows: equity, amountKey: 'balance'),
                    _Highlight(
                      label: 'Assets less liabilities and equity',
                      value: sum(assets) - sum(liabilities) - sum(equity),
                      emphasise: true,
                    ),
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        'This should be zero once the year-end profit is '
                        'transferred to retained earnings.',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _TrialBalance extends ConsumerWidget {
  const _TrialBalance();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(trialBalanceProvider);

    return AsyncView(
      value: data,
      onRetry: () => ref.invalidate(trialBalanceProvider),
      builder: (rows) {
        final active = rows
            .where((r) =>
                Fmt.toDouble(r['debit']) != 0 ||
                Fmt.toDouble(r['credit']) != 0 ||
                Fmt.toDouble(r['closing_balance']) != 0)
            .toList();

        if (active.isEmpty) {
          return const EmptyState(
            icon: Icons.table_chart_outlined,
            title: 'No ledger activity',
            message: 'The trial balance fills in as you post documents.',
          );
        }

        final totalDebit =
            active.fold<double>(0, (s, r) => s + Fmt.toDouble(r['debit']));
        final totalCredit =
            active.fold<double>(0, (s, r) => s + Fmt.toDouble(r['credit']));

        return SingleChildScrollView(
          child: PageBody(
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SectionHeader(
                      'Trial Balance',
                      subtitle: totalDebit == totalCredit
                          ? 'In balance'
                          : 'Out of balance by ${Fmt.money(totalDebit - totalCredit)}',
                    ),
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: ConstrainedBox(
                        constraints: BoxConstraints(
                          minWidth: MediaQuery.sizeOf(context).width - 120,
                        ),
                        child: DataTable(
                          columnSpacing: 24,
                          columns: const [
                            DataColumn(label: Text('Code')),
                            DataColumn(label: Text('Account')),
                            DataColumn(label: Text('Debit'), numeric: true),
                            DataColumn(label: Text('Credit'), numeric: true),
                            DataColumn(label: Text('Balance'), numeric: true),
                          ],
                          rows: [
                            for (final r in active)
                              DataRow(cells: [
                                DataCell(Text(r['code']?.toString() ?? '')),
                                DataCell(Text(r['name']?.toString() ?? '')),
                                DataCell(Money(Fmt.toDouble(r['debit']))),
                                DataCell(Money(Fmt.toDouble(r['credit']))),
                                DataCell(Money(
                                  Fmt.toDouble(r['closing_balance']),
                                  colorNegative: true,
                                )),
                              ]),
                            DataRow(
                              color: WidgetStatePropertyAll(
                                Theme.of(context)
                                    .colorScheme
                                    .surfaceContainerHighest,
                              ),
                              cells: [
                                const DataCell(Text('')),
                                const DataCell(Text('Total',
                                    style: TextStyle(
                                        fontWeight: FontWeight.w700))),
                                DataCell(Money(totalDebit, bold: true)),
                                DataCell(Money(totalCredit, bold: true)),
                                const DataCell(Text('')),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _SstSummary extends ConsumerWidget {
  const _SstSummary({required this.range});

  final DateTimeRange range;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(_sstProvider(range));

    return AsyncView(
      value: data,
      onRetry: () => ref.invalidate(_sstProvider),
      builder: (rows) {
        if (rows.isEmpty) {
          return const EmptyState(
            icon: Icons.receipt_outlined,
            title: 'No taxable transactions',
            message: 'SST figures appear once you post documents with tax.',
          );
        }

        final output = rows.where((r) => r['direction'] == 'output').toList();
        final input = rows.where((r) => r['direction'] == 'input').toList();

        double tax(List<Map<String, dynamic>> l) =>
            l.fold(0, (s, r) => s + Fmt.toDouble(r['tax_amount']));

        final payable = tax(output) - tax(input);

        return SingleChildScrollView(
          child: PageBody(
            maxWidth: 860,
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SectionHeader(
                      'SST Summary',
                      subtitle: 'Supporting figures for the SST-02 return · '
                          '${Fmt.longDate(range.start)} to ${Fmt.longDate(range.end)}',
                    ),
                    _SstTable(title: 'Output tax (sales)', rows: output),
                    const SizedBox(height: 20),
                    _SstTable(title: 'Input tax (purchases)', rows: input),
                    _Highlight(
                      label: payable >= 0 ? 'Tax payable' : 'Tax reclaimable',
                      value: payable.abs(),
                      emphasise: true,
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _SstTable extends StatelessWidget {
  const _SstTable({required this.title, required this.rows});

  final String title;
  final List<Map<String, dynamic>> rows;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
        const SizedBox(height: 8),
        if (rows.isEmpty)
          Text('None', style: Theme.of(context).textTheme.bodySmall)
        else
          for (final r in rows)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 5),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '${r['tax_type_code']} — ${r['tax_type_name']}',
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  SizedBox(
                    width: 140,
                    child: Money(Fmt.toDouble(r['taxable_amount'])),
                  ),
                  SizedBox(
                    width: 120,
                    child: Money(Fmt.toDouble(r['tax_amount']), bold: true),
                  ),
                ],
              ),
            ),
      ],
    );
  }
}

final _profitLossProvider = FutureProvider.autoDispose
    .family<List<Map<String, dynamic>>, DateTimeRange>((ref, range) {
  return requireRepo(ref).profitLoss(from: range.start, to: range.end);
});

final _balanceSheetProvider = FutureProvider.autoDispose
    .family<List<Map<String, dynamic>>, DateTime>((ref, asAt) {
  return requireRepo(ref).balanceSheet(asAt: asAt);
});

final _sstProvider = FutureProvider.autoDispose
    .family<List<Map<String, dynamic>>, DateTimeRange>((ref, range) {
  return requireRepo(ref).sstSummary(from: range.start, to: range.end);
});
