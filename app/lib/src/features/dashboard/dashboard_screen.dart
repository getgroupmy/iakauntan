import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/models.dart';

class DashboardScreen extends ConsumerWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final summary = ref.watch(dashboardProvider);
    final org = ref.watch(currentOrgProvider).value;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Dashboard'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            onPressed: () => refreshLedgerData(ref),
            icon: const Icon(Icons.refresh),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          refreshLedgerData(ref);
          await ref.read(dashboardProvider.future);
        },
        child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          child: PageBody(
            child: AsyncView(
              value: summary,
              onRetry: () => ref.invalidate(dashboardProvider),
              builder: (data) => Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _Greeting(orgName: org?.name ?? ''),
                  const SizedBox(height: 20),
                  _MetricGrid(data: data),
                  const SizedBox(height: 24),
                  if (data.einvoiceInvalid > 0 || data.einvoicePending > 0)
                    _EinvoiceBanner(data: data),
                  const _TrendCard(),
                  const SizedBox(height: 20),
                  const _TwoColumn(
                    left: _ReceivablesCard(),
                    right: _ActivitiesCard(),
                  ),
                  const SizedBox(height: 32),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Greeting extends StatelessWidget {
  const _Greeting({required this.orgName});

  final String orgName;

  @override
  Widget build(BuildContext context) {
    final hour = DateTime.now().hour;
    final greeting = hour < 12
        ? 'Selamat pagi'
        : hour < 19
            ? 'Selamat petang'
            : 'Selamat malam';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          greeting,
          style: Theme.of(context)
              .textTheme
              .headlineSmall
              ?.copyWith(fontWeight: FontWeight.w700, letterSpacing: -0.5),
        ),
        const SizedBox(height: 2),
        Text(
          '$orgName · ${Fmt.longDate(DateTime.now())}',
          style: Theme.of(context).textTheme.bodyMedium,
        ),
      ],
    );
  }
}

class _MetricGrid extends ConsumerWidget {
  const _MetricGrid({required this.data});

  final DashboardSummary data;

  /// Month-on-month change, or null when there is not enough history to
  /// claim one. A first month in business is not a 100% rise.
  static double? _delta(List<double> series) {
    if (series.length < 2) return null;
    final previous = series[series.length - 2];
    if (previous == 0) return null;
    return (series.last - previous) / previous;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final width = MediaQuery.sizeOf(context).width;
    final columns = width >= 1100 ? 4 : (width >= 700 ? 2 : 1);

    // The same series the chart below uses; the tiles show its shape so the
    // top row answers "which way is this going" without scrolling.
    final rows = ref.watch(revenueTrendProvider).valueOrNull ?? const [];
    final revenueSeries = [
      for (final r in rows) Fmt.toDouble(r['revenue']),
    ];
    final expenseSeries = [
      for (final r in rows) Fmt.toDouble(r['expenses']),
    ];

    final tiles = <Widget>[
      StatTile(
        label: 'Revenue this month',
        value: Fmt.money(data.revenue),
        caption: 'Invoiced, excluding drafts',
        icon: Icons.trending_up,
        accent: context.colors.success,
        trend: revenueSeries,
        delta: _delta(revenueSeries),
      ),
      StatTile(
        label: 'Expenses this month',
        value: Fmt.money(data.expenses),
        caption: 'Supplier bills',
        icon: Icons.trending_down,
        accent: context.colors.warning,
        trend: expenseSeries,
        delta: _delta(expenseSeries),
        // Spending more than last month is not an achievement.
        deltaIsGood: false,
      ),
      StatTile(
        label: 'Receivables',
        value: Fmt.money(data.receivables),
        caption: data.overdueReceivables > 0
            ? '${Fmt.money(data.overdueReceivables)} overdue'
            : 'Nothing overdue',
        icon: Icons.account_balance_wallet_outlined,
        accent: data.overdueReceivables > 0 ? context.colors.danger : null,
      ),
      StatTile(
        label: 'Bank balance',
        value: Fmt.money(data.bankBalance),
        caption: 'Across active accounts',
        icon: Icons.account_balance,
        accent: context.colors.info,
      ),
    ];

    return GridView.count(
      crossAxisCount: columns,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: 12,
      crossAxisSpacing: 12,
      childAspectRatio: columns == 1 ? 3.2 : 1.75,
      children: tiles,
    );
  }
}

class _EinvoiceBanner extends ConsumerWidget {
  const _EinvoiceBanner({required this.data});

  final DashboardSummary data;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final needsAttention = data.einvoiceInvalid > 0;
    final color = needsAttention ? context.colors.danger : context.colors.warning;

    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Card(
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: () => context.go('/einvoice'),
          child: Padding(
            padding: const EdgeInsets.all(Space.lg),
            child: Row(
              children: [
                Icon(
                  needsAttention ? Icons.error_outline : Icons.schedule,
                  color: color,
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        needsAttention
                            ? '${data.einvoiceInvalid} e-Invoice(s) rejected by LHDN'
                            : '${data.einvoicePending} e-Invoice(s) awaiting validation',
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        needsAttention
                            ? 'Fix the validation errors and resubmit.'
                            : 'MyInvois usually validates within a few minutes.',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                const Icon(Icons.chevron_right),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _TrendCard extends ConsumerWidget {
  const _TrendCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final trend = ref.watch(revenueTrendProvider);
    final scheme = Theme.of(context).colorScheme;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Space.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SectionHeader(
              'Revenue vs expenses',
              subtitle: 'Last 12 months',
            ),
            SizedBox(
              height: 240,
              child: AsyncView(
                value: trend,
                onRetry: () => ref.invalidate(revenueTrendProvider),
                builder: (rows) {
                  if (rows.isEmpty) {
                    return const EmptyState(
                      icon: Icons.show_chart,
                      title: 'No data yet',
                      message: 'Post your first invoice to see the trend.',
                    );
                  }

                  final revenue = <FlSpot>[];
                  final expenses = <FlSpot>[];
                  var maxY = 0.0;

                  for (var i = 0; i < rows.length; i++) {
                    final r = Fmt.toDouble(rows[i]['revenue']);
                    final e = Fmt.toDouble(rows[i]['expenses']);
                    revenue.add(FlSpot(i.toDouble(), r));
                    expenses.add(FlSpot(i.toDouble(), e));
                    maxY = [maxY, r, e].reduce((a, b) => a > b ? a : b);
                  }

                  return LineChart(
                    LineChartData(
                      minY: 0,
                      maxY: maxY == 0 ? 1000 : maxY * 1.2,
                      gridData: FlGridData(
                        drawVerticalLine: false,
                        getDrawingHorizontalLine: (_) => FlLine(
                          color: scheme.outlineVariant.withValues(alpha: 0.5),
                          strokeWidth: 1,
                        ),
                      ),
                      borderData: FlBorderData(show: false),
                      titlesData: FlTitlesData(
                        topTitles: const AxisTitles(),
                        rightTitles: const AxisTitles(),
                        leftTitles: AxisTitles(
                          sideTitles: SideTitles(
                            showTitles: true,
                            reservedSize: 48,
                            getTitlesWidget: (value, meta) => Text(
                              Fmt.compact(value),
                              style: const TextStyle(fontSize: 10),
                            ),
                          ),
                        ),
                        bottomTitles: AxisTitles(
                          sideTitles: SideTitles(
                            showTitles: true,
                            interval: rows.length > 6 ? 2 : 1,
                            getTitlesWidget: (value, meta) {
                              final i = value.toInt();
                              if (i < 0 || i >= rows.length) {
                                return const SizedBox.shrink();
                              }
                              final period = Fmt.parseDate(rows[i]['period']);
                              return Padding(
                                padding: const EdgeInsets.only(top: 6),
                                child: Text(
                                  period == null
                                      ? ''
                                      : Fmt.monthYear(period).split(' ').first,
                                  style: const TextStyle(fontSize: 10),
                                ),
                              );
                            },
                          ),
                        ),
                      ),
                      lineBarsData: [
                        _line(revenue, context.colors.success),
                        _line(expenses, context.colors.warning),
                      ],
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                _Legend(color: context.colors.success, label: 'Revenue'),
                SizedBox(width: 20),
                _Legend(color: context.colors.warning, label: 'Expenses'),
              ],
            ),
          ],
        ),
      ),
    );
  }

  static LineChartBarData _line(List<FlSpot> spots, Color color) =>
      LineChartBarData(
        spots: spots,
        isCurved: true,
        curveSmoothness: 0.25,
        color: color,
        barWidth: 2.5,
        dotData: const FlDotData(show: false),
        belowBarData: BarAreaData(
          show: true,
          color: color.withValues(alpha: 0.10),
        ),
      );
}

class _Legend extends StatelessWidget {
  const _Legend({required this.color, required this.label});

  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 6),
        Text(label, style: Theme.of(context).textTheme.bodySmall),
      ],
    );
  }
}

class _ReceivablesCard extends ConsumerWidget {
  const _ReceivablesCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final aging = ref.watch(arAgingProvider);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Space.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SectionHeader(
              'Outstanding invoices',
              action: TextButton(
                onPressed: () => context.go('/sales/invoice'),
                child: const Text('View all'),
              ),
            ),
            AsyncView(
              value: aging,
              onRetry: () => ref.invalidate(arAgingProvider),
              loading: const SizedBox(
                height: 120,
                child: Center(child: CircularProgressIndicator()),
              ),
              builder: (rows) {
                if (rows.isEmpty) {
                  return const EmptyState(
                    icon: Icons.check_circle_outline,
                    title: 'All settled',
                    message: 'No outstanding customer invoices.',
                  );
                }
                return Column(
                  children: [
                    for (final row in rows.take(6))
                      ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        title: Text(
                          row['contact_name']?.toString() ?? '—',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w500),
                        ),
                        subtitle: Text(
                          '${row['doc_no']} · due ${Fmt.date(Fmt.parseDate(row['due_date']))}',
                          style: const TextStyle(fontSize: 12),
                        ),
                        trailing: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Money(
                              Fmt.toDouble(row['balance_amount']),
                              currency: row['currency']?.toString() ?? 'MYR',
                              bold: true,
                            ),
                            if (Fmt.toInt(row['days_overdue']) > 0)
                              Text(
                                '${row['days_overdue']} days late',
                                style: TextStyle(
                                  fontSize: 11,
                                  color: context.colors.danger,
                                ),
                              ),
                          ],
                        ),
                      ),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _ActivitiesCard extends ConsumerWidget {
  const _ActivitiesCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final activities = ref.watch(activitiesProvider);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Space.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SectionHeader(
              'Upcoming activities',
              action: TextButton(
                onPressed: () => context.go('/crm'),
                child: const Text('Pipeline'),
              ),
            ),
            AsyncView(
              value: activities,
              onRetry: () => ref.invalidate(activitiesProvider),
              loading: const SizedBox(
                height: 120,
                child: Center(child: CircularProgressIndicator()),
              ),
              builder: (rows) {
                if (rows.isEmpty) {
                  return const EmptyState(
                    icon: Icons.event_available,
                    title: 'Nothing scheduled',
                    message: 'Follow-ups you plan will show up here.',
                  );
                }
                return Column(
                  children: [
                    for (final row in rows.take(6))
                      ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: CircleAvatar(
                          radius: 16,
                          backgroundColor: Theme.of(context)
                              .colorScheme
                              .primaryContainer,
                          child: Icon(
                            _activityIcon(row['activity_type']?.toString()),
                            size: 15,
                          ),
                        ),
                        title: Text(
                          row['subject']?.toString() ?? '—',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          Fmt.dateTime(Fmt.parseDate(row['due_date'])),
                          style: const TextStyle(fontSize: 12),
                        ),
                      ),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  static IconData _activityIcon(String? type) => switch (type) {
        'call' => Icons.phone,
        'email' => Icons.mail_outline,
        'meeting' => Icons.groups_outlined,
        'whatsapp' => Icons.chat_bubble_outline,
        'site_visit' => Icons.place_outlined,
        'demo' => Icons.slideshow_outlined,
        _ => Icons.task_alt,
      };
}

/// Side-by-side on desktop, stacked on narrow screens.
class _TwoColumn extends StatelessWidget {
  const _TwoColumn({required this.left, required this.right});

  final Widget left;
  final Widget right;

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.sizeOf(context).width < 900) {
      return Column(children: [left, const SizedBox(height: 20), right]);
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(child: left),
        const SizedBox(width: 20),
        Expanded(child: right),
      ],
    );
  }
}
