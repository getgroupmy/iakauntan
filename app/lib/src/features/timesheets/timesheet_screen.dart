import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/repository.dart';
import 'billing_rate_sheet.dart';
import 'time_entry_sheet.dart';

/// Time recorded, and time turned into an invoice.
///
/// Two tabs because there are two jobs here and they belong to different
/// people. *My week* is what a fee earner fills in on a Friday. *Unbilled*
/// is what whoever raises the invoices looks at on a Monday, and it is
/// the tab that matters: hours that never become an invoice are the
/// whole failure mode of selling time.
class TimesheetScreen extends ConsumerStatefulWidget {
  const TimesheetScreen({super.key});

  @override
  ConsumerState<TimesheetScreen> createState() => _TimesheetScreenState();
}

class _TimesheetScreenState extends ConsumerState<TimesheetScreen> {
  late DateTime _from;
  late DateTime _to;

  @override
  void initState() {
    super.initState();
    // The current month. A week would be truer to how time is recorded
    // and worse for the tab next door, which is asked about a month.
    final now = DateTime.now();
    _from = DateTime(now.year, now.month, 1);
    _to = DateTime(now.year, now.month + 1, 0);
  }

  @override
  Widget build(BuildContext context) {
    final period = (from: _from, to: _to);

    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Timesheets'),
          actions: [
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: OutlinedButton.icon(
                onPressed: () async {
                  final range = await showDateRangePicker(
                    context: context,
                    firstDate: DateTime(2020),
                    lastDate: DateTime(2100),
                    initialDateRange: DateTimeRange(start: _from, end: _to),
                  );
                  if (range != null) {
                    setState(() {
                      _from = range.start;
                      _to = range.end;
                    });
                  }
                },
                icon: const Icon(Icons.date_range, size: 18),
                label: Text('${Fmt.date(_from)} — ${Fmt.date(_to)}'),
              ),
            ),
          ],
          bottom: const TabBar(
            tabs: [
              Tab(text: 'My week'),
              Tab(text: 'Unbilled'),
              Tab(text: 'Rates'),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            _MyTime(period: period),
            _Unbilled(period: period),
            const _Rates(),
          ],
        ),
      ),
    );
  }
}

class _MyTime extends ConsumerWidget {
  const _MyTime({required this.period});

  final ({DateTime from, DateTime to}) period;

  /// Re-read everything an hour moves: this tab, the unbilled figure
  /// next door, and the utilisation the report is built from.
  void _refresh(WidgetRef ref) {
    ref.invalidate(myTimeEntriesProvider(period));
    ref.invalidate(timesheetReportProvider(period));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final entries = ref.watch(myTimeEntriesProvider(period));
    final canWrite = ref.watch(canWriteProvider);

    return Scaffold(
      floatingActionButton: canWrite
          ? FloatingActionButton.extended(
              key: const ValueKey('record-time'),
              onPressed: () async {
                if (await showTimeEntrySheet(context)) _refresh(ref);
              },
              icon: const Icon(Icons.timer_outlined),
              label: const Text('Record time'),
            )
          : null,
      body: _body(context, ref, entries, canWrite),
    );
  }

  Widget _body(
    BuildContext context,
    WidgetRef ref,
    AsyncValue<List<Map<String, dynamic>>> entries,
    bool canWrite,
  ) {
    return AsyncView(
      value: entries,
      onRetry: () => ref.invalidate(myTimeEntriesProvider(period)),
      builder: (list) {
        if (list.isEmpty) {
          return const EmptyState(
            icon: Icons.schedule_outlined,
            title: 'No time recorded',
            message:
                'Record hours against a project or a matter. The rate comes '
                'from your billing rate, so there is no need to know it.',
          );
        }

        final minutes = list.fold<num>(
          0,
          (a, e) => a + (e['minutes'] as num? ?? 0),
        );
        final billable = list
            .where((e) => e['is_billable'] == true)
            .fold<num>(0, (a, e) => a + (e['minutes'] as num? ?? 0));

        return Column(
          children: [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(Space.lg),
              color: Theme.of(
                context,
              ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
              child: Text(
                '${(minutes / 60).toStringAsFixed(2)} hours recorded, '
                '${(billable / 60).toStringAsFixed(2)} of them chargeable.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
            Expanded(
              child: ListView.separated(
                padding: const EdgeInsets.only(bottom: 88),
                itemCount: list.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (context, i) {
                  final e = list[i];
                  final billed = e['is_billed'] == true;
                  final project = e['projects'] as Map<String, dynamic>?;
                  final matter = e['matters'] as Map<String, dynamic>?;
                  final against =
                      project?['name'] as String? ??
                      matter?['name'] as String? ??
                      'Not chargeable to anyone';
                  return ListTile(
                    // A billed hour is a line on an invoice somebody has
                    // been sent; changing it here would move the hours
                    // and leave the invoice where it was.
                    onTap: !canWrite || !timeEntryIsEditable(billed)
                        ? null
                        : () async {
                            if (await showTimeEntrySheet(
                              context,
                              id: e['id'] as String,
                              existing: e,
                            )) {
                              _refresh(ref);
                            }
                          },
                    title: Text(
                      e['description'] as String? ?? '—',
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    subtitle: Text(
                      '${Fmt.date(DateTime.parse(e['entry_date'] as String))} '
                      '· $against · '
                      '${((e['minutes'] as num? ?? 0) / 60).toStringAsFixed(2)}h',
                      style: const TextStyle(fontSize: 12),
                    ),
                    trailing: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Money(e['amount'] as num?, bold: true),
                        if (billed)
                          const StatusChip('billed', compact: true)
                        else if (e['is_billable'] != true)
                          const StatusChip('internal', compact: true),
                      ],
                    ),
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }
}

class _Unbilled extends ConsumerWidget {
  const _Unbilled({required this.period});

  final ({DateTime from, DateTime to}) period;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final projects = ref.watch(projectsProvider);
    final report = ref.watch(timesheetReportProvider(period));

    return AsyncView(
      value: projects,
      onRetry: () => ref.invalidate(projectsProvider),
      builder: (list) {
        if (list.isEmpty) {
          return const EmptyState(
            icon: Icons.folder_outlined,
            title: 'No projects yet',
            message:
                'A project is what hours are recorded against and what they '
                'are billed to. Give it a client, and the time on it can be '
                'invoiced.',
          );
        }
        return ListView(
          children: [
            // Who has been doing what, and how much of it has never been
            // invoiced. The last figure is the one worth the screen.
            report.maybeWhen(
              data: (rows) => rows.isEmpty
                  ? const SizedBox.shrink()
                  : _Utilisation(rows: rows),
              orElse: () => const SizedBox.shrink(),
            ),
            for (final p in list) _ProjectTile(project: p, period: period),
          ],
        );
      },
    );
  }
}

class _Utilisation extends StatelessWidget {
  const _Utilisation({required this.rows});

  final List<Map<String, dynamic>> rows;

  @override
  Widget build(BuildContext context) {
    final unbilled = rows.fold<num>(
      0,
      (a, r) => a + (r['unbilled_amount'] as num? ?? 0),
    );

    return Card(
      margin: const EdgeInsets.all(Space.lg),
      child: Padding(
        padding: const EdgeInsets.all(Space.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Recorded but not invoiced',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
                Money(unbilled, bold: true),
              ],
            ),
            const SizedBox(height: 8),
            for (final r in rows)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  children: [
                    Expanded(child: Text(r['who'] as String? ?? '—')),
                    Text(
                      '${r['billable_hours']}h chargeable'
                      '${r['utilisation_percent'] == null ? '' : ' · ${r['utilisation_percent']}%'}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    const SizedBox(width: 12),
                    Money(r['unbilled_amount'] as num?),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _ProjectTile extends ConsumerWidget {
  const _ProjectTile({required this.project, required this.period});

  final Map<String, dynamic> project;
  final ({DateTime from, DateTime to}) period;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final id = project['id'] as String;
    final unbilled = ref.watch(unbilledTimeProvider(id));
    final client = project['contacts'] as Map<String, dynamic>?;

    return unbilled.maybeWhen(
      data: (rows) {
        final amount = rows.fold<num>(
          0,
          (a, e) => a + (e['amount'] as num? ?? 0),
        );
        final minutes = rows.fold<num>(
          0,
          (a, e) => a + (e['minutes'] as num? ?? 0),
        );
        return ListTile(
          title: Text(
            project['name'] as String? ?? '—',
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          subtitle: Text(
            client == null
                ? 'No client — time on this cannot be invoiced'
                : '${client['name']} · '
                      '${(minutes / 60).toStringAsFixed(2)}h unbilled',
            style: TextStyle(
              fontSize: 12,
              color: client == null ? context.colors.warning : null,
            ),
          ),
          trailing: rows.isEmpty || client == null
              ? Money(amount)
              : FilledButton(
                  onPressed: () => _bill(context, ref, id),
                  child: Text('Bill ${Fmt.money(amount)}'),
                ),
        );
      },
      orElse: () => ListTile(
        title: Text(project['name'] as String? ?? '—'),
        trailing: const SizedBox(
          height: 16,
          width: 16,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      ),
    );
  }

  Future<void> _bill(BuildContext context, WidgetRef ref, String id) async {
    final ok = await runWithFeedback(
      context,
      action: () =>
          ref.read(repoProvider)!.billProjectTime(id, period.from, period.to),
      successMessage: 'Invoice raised and posted',
      pendingMessage: 'Billing…',
    );
    if (ok) {
      ref.invalidate(unbilledTimeProvider(id));
      ref.invalidate(timesheetReportProvider(period));
      ref.invalidate(documentsProvider);
    }
  }
}

/// What everybody charges.
///
/// `billing_rates` has been in `0164` with a provider reading it and
/// nothing displaying it, and nothing anywhere adding a row -- so the
/// rate card was invisible and unmaintainable, and every hour had its
/// rate typed in by hand.
class _Rates extends ConsumerWidget {
  const _Rates();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rates = ref.watch(billingRatesProvider);
    final canWrite = ref.watch(canWriteProvider);

    return Scaffold(
      floatingActionButton: canWrite
          ? FloatingActionButton.extended(
              key: const ValueKey('add-rate'),
              onPressed: () => showBillingRateSheet(context),
              icon: const Icon(Icons.add),
              label: const Text('Record a rate'),
            )
          : null,
      body: AsyncView(
        value: rates,
        onRetry: () => ref.invalidate(billingRatesProvider),
        builder: (list) {
          if (list.isEmpty) {
            return const EmptyState(
              icon: Icons.price_change_outlined,
              title: 'No rates recorded',
              message: 'Record what each person charges, and the rate stops '
                  'being something typed from memory onto every entry.',
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.only(bottom: 88),
            itemCount: list.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (context, i) {
              final r = list[i];
              final project = r['projects'] as Map<String, dynamic>?;
              return ListTile(
                title: Text(
                  rateScope(r['project_id'] as String?),
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                subtitle: Text(
                  [
                    if (project != null) '${project['code']} · ${project['name']}',
                    'from ${Fmt.date(DateTime.parse(r['effective_from'] as String))}',
                    if (r['notes'] != null) '${r['notes']}',
                  ].join(' · '),
                  style: const TextStyle(fontSize: 12),
                ),
                trailing: Money(r['hourly_rate'] as num?, bold: true),
              );
            },
          );
        },
      ),
    );
  }
}
