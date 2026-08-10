import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/models.dart';
import '../../data/repository.dart';

/// Payroll runs. A run is calculated, checked, then posted — posting is
/// what writes the journal and moves the year-to-date figures, so it is
/// deliberately a separate, irreversible-feeling step.
class PayrollScreen extends ConsumerWidget {
  const PayrollScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final runs = ref.watch(payrollRunsProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Payroll'),
        actions: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Space.md),
            child: FilledButton.icon(
              onPressed: () => _startRun(context, ref),
              icon: const Icon(Icons.play_arrow, size: 18),
              label: const Text('New run'),
            ),
          ),
        ],
      ),
      body: AsyncView(
        value: runs,
        onRetry: () => ref.invalidate(payrollRunsProvider),
        builder: (list) => list.isEmpty
            ? const EmptyState(
                icon: Icons.payments_outlined,
                title: 'No payroll runs yet',
                message: 'Start a run for the current month. Nothing is posted '
                    'to the ledger until you say so.',
              )
            : ListView.separated(
                itemCount: list.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (_, i) => _RunTile(run: list[i]),
              ),
      ),
    );
  }

  Future<void> _startRun(BuildContext context, WidgetRef ref) async {
    final now = DateTime.now();
    final month = await showDialog<DateTime>(
      context: context,
      builder: (_) => _MonthPickerDialog(initial: DateTime(now.year, now.month)),
    );
    if (month == null || !context.mounted) return;

    final repo = ref.read(repoProvider)!;
    String? runId;
    await runWithFeedback(
      context,
      action: () async {
        runId = await repo.startPayrollRun(month.year, month.month);
        await repo.calculatePayroll(runId!);
      },
      successMessage: 'Calculated — review before posting',
    );
    ref.invalidate(payrollRunsProvider);
  }
}

class _RunTile extends ConsumerWidget {
  const _RunTile({required this.run});

  final PayrollRun run;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ListTile(
      onTap: () => context.go('/hr/payroll/${run.id}'),
      contentPadding:
          const EdgeInsets.symmetric(horizontal: Space.lg, vertical: Space.sm),
      title: Row(children: [
        Text(run.runNo, style: const TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(width: Space.sm),
        StatusChip(run.status, compact: true),
      ]),
      subtitle: Text(
        '${run.periodCode ?? '—'} · ${run.employeeCount} employees · '
        'paid ${Fmt.date(run.payDate)}',
        style: const TextStyle(fontSize: 12),
      ),
      trailing: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Money(run.totalNet, bold: true),
          Text('net pay',
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: context.scheme.onSurfaceVariant)),
        ],
      ),
    );
  }
}

/// One run: the totals that matter, the statutory breakdown, and the
/// payslips it produced.
class PayrollRunScreen extends ConsumerWidget {
  const PayrollRunScreen({super.key, required this.runId});

  final String runId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final runs = ref.watch(payrollRunsProvider);
    final payslips = ref.watch(payslipsForRunProvider(runId));

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.go('/hr/payroll'),
        ),
        title: Text(runs.valueOrNull
                ?.where((r) => r.id == runId)
                .firstOrNull
                ?.runNo ??
            'Payroll run'),
      ),
      body: AsyncView(
        value: runs,
        onRetry: () => ref.invalidate(payrollRunsProvider),
        builder: (list) {
          final run = list.where((r) => r.id == runId).firstOrNull;
          if (run == null) {
            return const EmptyState(
                icon: Icons.error_outline, title: 'Run not found');
          }
          return SingleChildScrollView(
            child: PageBody(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _RunHeader(run: run),
                  const SizedBox(height: Space.lg),
                  _StatutoryCard(run: run),
                  const SizedBox(height: Space.lg),
                  _PayslipsCard(payslips: payslips),
                  const SizedBox(height: Space.xxl),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _RunHeader extends ConsumerWidget {
  const _RunHeader({required this.run});

  final PayrollRun run;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Space.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              StatusChip(run.status),
              const SizedBox(width: Space.md),
              Expanded(
                child: Text(
                  '${run.periodCode ?? ''} · ${run.employeeCount} employees',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              if (run.status == 'calculated')
                FilledButton.icon(
                  onPressed: () => _post(context, ref),
                  icon: const Icon(Icons.check, size: 18),
                  label: const Text('Post to ledger'),
                )
              else if (run.status == 'draft')
                FilledButton.icon(
                  onPressed: () => _calculate(context, ref),
                  icon: const Icon(Icons.calculate_outlined, size: 18),
                  label: const Text('Calculate'),
                ),
            ]),
            const SizedBox(height: Space.lg),
            Wrap(spacing: Space.xxl, runSpacing: Space.md, children: [
              _Figure(label: 'Gross pay', value: run.totalGross),
              _Figure(label: 'Deductions', value: run.totalDeductions),
              _Figure(label: 'Net pay', value: run.totalNet, emphasise: true),
              _Figure(
                  label: 'Total cost to company', value: run.totalEmployerCost),
            ]),
          ],
        ),
      ),
    );
  }

  Future<void> _calculate(BuildContext context, WidgetRef ref) async {
    await runWithFeedback(
      context,
      action: () => ref.read(repoProvider)!.calculatePayroll(run.id),
      successMessage: 'Calculated',
    );
    ref.invalidate(payrollRunsProvider);
    ref.invalidate(payslipsForRunProvider(run.id));
  }

  Future<void> _post(BuildContext context, WidgetRef ref) async {
    final ok = await confirm(
      context,
      title: 'Post ${run.runNo} to the ledger?',
      message: 'This writes the payroll journal and rolls the year-to-date '
          'figures forward, which the next month’s PCB is calculated from. '
          'It cannot be undone from here.',
      confirmLabel: 'Post',
    );
    if (!ok || !context.mounted) return;

    await runWithFeedback(
      context,
      action: () => ref.read(repoProvider)!.postPayroll(run.id),
      successMessage: 'Posted to the ledger',
    );
    ref.invalidate(payrollRunsProvider);
    refreshLedgerData(ref);
  }
}

class _Figure extends StatelessWidget {
  const _Figure({
    required this.label,
    required this.value,
    this.emphasise = false,
  });

  final String label;
  final double value;
  final bool emphasise;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label,
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: context.scheme.onSurfaceVariant)),
        const SizedBox(height: 2),
        Text(Fmt.money(value),
            style: (emphasise
                    ? Theme.of(context).textTheme.headlineSmall
                    : Theme.of(context).textTheme.titleLarge)
                ?.copyWith(fontWeight: FontWeight.w700)),
      ],
    );
  }
}

class _StatutoryCard extends StatelessWidget {
  const _StatutoryCard({required this.run});

  final PayrollRun run;

  @override
  Widget build(BuildContext context) {
    final rows = <(String, double, double)>[
      ('EPF / KWSP', run.totalEpfEmployee, run.totalEpfEmployer),
      ('SOCSO / PERKESO', run.totalSocsoEmployee, run.totalSocsoEmployer),
      ('EIS / SIP', run.totalEisEmployee, run.totalEisEmployer),
      ('PCB / MTD', run.totalPcb, 0),
      ('HRD Corp levy', 0, run.totalHrdf),
    ];

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Space.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SectionHeader('Statutory',
                subtitle: 'What has to be remitted for this period'),
            Row(children: [
              const Expanded(flex: 3, child: SizedBox()),
              Expanded(
                child: Text('Employee',
                    textAlign: TextAlign.right,
                    style: Theme.of(context).textTheme.labelSmall),
              ),
              Expanded(
                child: Text('Employer',
                    textAlign: TextAlign.right,
                    style: Theme.of(context).textTheme.labelSmall),
              ),
            ]),
            const Divider(),
            for (final r in rows)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: Space.xs),
                child: Row(children: [
                  Expanded(flex: 3, child: Text(r.$1)),
                  Expanded(child: Money(r.$2)),
                  Expanded(child: Money(r.$3)),
                ]),
              ),
          ],
        ),
      ),
    );
  }
}

class _PayslipsCard extends StatelessWidget {
  const _PayslipsCard({required this.payslips});

  final AsyncValue<List<Payslip>> payslips;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Space.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SectionHeader('Payslips'),
            payslips.when(
              loading: () => const LinearProgressIndicator(),
              error: (e, _) => Text('$e'),
              data: (list) => Column(children: [
                for (var i = 0; i < list.length; i++) ...[
                  if (i > 0) const Divider(height: 1),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    onTap: () => context.go('/hr/payslip/${list[i].id}'),
                    title: Text(list[i].employeeName,
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                    subtitle: Text(
                      '${list[i].employeeNo ?? ''} · gross '
                      '${Fmt.money(list[i].grossPay)} · EPF '
                      '${Fmt.money(list[i].epfEmployee)} · PCB '
                      '${Fmt.money(list[i].pcb)}',
                      style: const TextStyle(fontSize: 12),
                    ),
                    trailing: Money(list[i].netPay, bold: true),
                  ),
                ],
              ]),
            ),
          ],
        ),
      ),
    );
  }
}

class _MonthPickerDialog extends StatefulWidget {
  const _MonthPickerDialog({required this.initial});

  final DateTime initial;

  @override
  State<_MonthPickerDialog> createState() => _MonthPickerDialogState();
}

class _MonthPickerDialogState extends State<_MonthPickerDialog> {
  late int _year = widget.initial.year;
  late int _month = widget.initial.month;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Which month?'),
      content: SizedBox(
        width: 340,
        child: Row(children: [
          Expanded(
            child: DropdownButtonFormField<int>(
              value: _month,
              decoration: const InputDecoration(labelText: 'Month'),
              items: [
                for (var m = 1; m <= 12; m++)
                  DropdownMenuItem(value: m, child: Text(Fmt.monthName(m))),
              ],
              onChanged: (v) => setState(() => _month = v ?? _month),
            ),
          ),
          const SizedBox(width: Space.md),
          Expanded(
            child: DropdownButtonFormField<int>(
              value: _year,
              decoration: const InputDecoration(labelText: 'Year'),
              items: [
                for (var y = DateTime.now().year - 1;
                    y <= DateTime.now().year + 1;
                    y++)
                  DropdownMenuItem(value: y, child: Text('$y')),
              ],
              onChanged: (v) => setState(() => _year = v ?? _year),
            ),
          ),
        ]),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, DateTime(_year, _month)),
          child: const Text('Calculate'),
        ),
      ],
    );
  }
}
