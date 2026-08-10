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
    final canRun = ref.watch(canRunPayrollProvider);
    final canRequest = ref.watch(canRequestPayslipAccessProvider);
    final granted = ref.watch(myPayslipAccessProvider).valueOrNull ?? false;

    // An auditor with no live grant gets the request form rather than an
    // empty list they cannot explain.
    if (!canRun && canRequest && !granted) {
      return const _RequestAccessScreen();
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Payroll'),
        actions: [
          if (!canRun)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: Space.md),
              child: Center(child: _GrantedBadge()),
            ),
          if (canRun)
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
            ? EmptyState(
                icon: Icons.payments_outlined,
                title: canRun ? 'No payroll runs yet' : 'Nothing in scope',
                message: canRun
                    ? 'Start a run for the current month. Nothing is posted '
                        'to the ledger until you say so.'
                    : 'No payroll run falls inside the period your access '
                        'covers.',
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
              if (!ref.watch(canRunPayrollProvider))
                const SizedBox.shrink()
              else if (run.status == 'calculated')
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


/// Shown in the app bar when payroll is visible only because a company
/// admin granted it — so it is never mistaken for having the job.
class _GrantedBadge extends ConsumerWidget {
  const _GrantedBadge();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final requests = ref.watch(payslipAccessRequestsProvider).valueOrNull;
    final live = requests?.where((r) => r.isLive).firstOrNull;

    return Tooltip(
      message: live?.expiresAt == null
          ? 'Read-only access granted by a company admin. Every payslip you '
              'open is recorded.'
          : 'Read-only access, expires ${Fmt.date(live!.expiresAt)}. Every '
              'payslip you open is recorded.',
      child: Container(
        padding: const EdgeInsets.symmetric(
            horizontal: Space.md, vertical: Space.xs),
        decoration: BoxDecoration(
          color: context.colors.info.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(Radii.sm),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.visibility_outlined, size: 15, color: context.colors.info),
          const SizedBox(width: Space.xs),
          Text(
            live?.expiresAt == null
                ? 'Read-only'
                : 'Read-only until ${Fmt.date(live!.expiresAt)}',
            style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: context.colors.info),
          ),
        ]),
      ),
    );
  }
}

/// What an auditor sees before anyone has let them in.
class _RequestAccessScreen extends ConsumerStatefulWidget {
  const _RequestAccessScreen();

  @override
  ConsumerState<_RequestAccessScreen> createState() =>
      _RequestAccessScreenState();
}

class _RequestAccessScreenState extends ConsumerState<_RequestAccessScreen> {
  final _formKey = GlobalKey<FormState>();
  final _reason = TextEditingController();
  DateTime _from = DateTime(DateTime.now().year, 1, 1);
  DateTime _to = DateTime(DateTime.now().year, 12, 31);
  bool _saving = false;

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final requests = ref.watch(payslipAccessRequestsProvider);
    final pending =
        requests.valueOrNull?.where((r) => r.isPending).firstOrNull;

    return Scaffold(
      appBar: AppBar(title: const Text('Payroll')),
      body: SingleChildScrollView(
        child: PageBody(
          maxWidth: 720,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(Space.xl),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.lock_outline,
                          size: 32, color: context.scheme.onSurfaceVariant),
                      const SizedBox(height: Space.md),
                      Text('Payslips are closed by default',
                          style: Theme.of(context).textTheme.titleLarge),
                      const SizedBox(height: Space.sm),
                      Text(
                        'What people are paid is not part of an auditor’s '
                        'standing access. Ask a company admin for it, saying '
                        'what it is for and over what period. Access is '
                        'read-only, lapses on its own, and every payslip you '
                        'open is recorded against the grant that allowed it.',
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                      const SizedBox(height: Space.xl),
                      if (pending != null)
                        _PendingNotice(request: pending)
                      else
                        _buildForm(context),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: Space.lg),
              _HistoryCard(requests: requests),
              const SizedBox(height: Space.xxl),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildForm(BuildContext context) {
    return Form(
      key: _formKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextFormField(
            controller: _reason,
            maxLines: 3,
            decoration: const InputDecoration(
              labelText: 'Why do you need it? *',
              helperText: 'The admin sees this, and it stays on the record',
            ),
            validator: (v) => (v ?? '').trim().length < 10
                ? 'Give a reason an admin can act on'
                : null,
          ),
          const SizedBox(height: Space.lg),
          Row(children: [
            Expanded(
              child: _DateField(
                label: 'Period from',
                value: _from,
                onChanged: (d) => setState(() => _from = d),
              ),
            ),
            const SizedBox(width: Space.md),
            Expanded(
              child: _DateField(
                label: 'Period to',
                value: _to,
                onChanged: (d) => setState(() => _to = d),
              ),
            ),
          ]),
          const SizedBox(height: Space.lg),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton.icon(
              onPressed: _saving ? null : _submit,
              icon: const Icon(Icons.send_outlined, size: 18),
              label: const Text('Request access'),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);

    await runWithFeedback(
      context,
      action: () => ref.read(repoProvider)!.requestPayslipAccess(
            reason: _reason.text.trim(),
            from: _from,
            to: _to,
          ),
      successMessage: 'Sent — a company admin has to approve it',
    );

    if (mounted) setState(() => _saving = false);
    ref.invalidate(payslipAccessRequestsProvider);
  }
}

class _PendingNotice extends StatelessWidget {
  const _PendingNotice({required this.request});

  final PayslipAccessRequest request;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(Space.lg),
      decoration: BoxDecoration(
        color: context.colors.warning.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(Radii.md),
        border:
            Border.all(color: context.colors.warning.withValues(alpha: 0.35)),
      ),
      child: Row(children: [
        Icon(Icons.schedule, color: context.colors.warning),
        const SizedBox(width: Space.md),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Waiting for a decision',
                  style: TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 2),
              Text(
                'Asked on ${Fmt.date(request.requestedAt)} for '
                '${request.scopeLabel.toLowerCase()}.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ]),
    );
  }
}

class _HistoryCard extends StatelessWidget {
  const _HistoryCard({required this.requests});

  final AsyncValue<List<PayslipAccessRequest>> requests;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Space.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SectionHeader('Your requests',
                subtitle: 'Every request and decision stays on the record'),
            requests.when(
              loading: () => const LinearProgressIndicator(),
              error: (e, _) => Text('$e'),
              data: (list) => list.isEmpty
                  ? Text('You have not asked for access before.',
                      style: Theme.of(context).textTheme.bodySmall)
                  : Column(children: [
                      for (var i = 0; i < list.length; i++) ...[
                        if (i > 0) const Divider(height: 1),
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          title: Row(children: [
                            Expanded(
                              child: Text(list[i].reason,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis),
                            ),
                            const SizedBox(width: Space.sm),
                            StatusChip(list[i].displayStatus, compact: true),
                          ]),
                          subtitle: Text(
                            [
                              list[i].scopeLabel,
                              'asked ${Fmt.date(list[i].requestedAt)}',
                              if (list[i].expiresAt != null)
                                'expires ${Fmt.date(list[i].expiresAt)}',
                              if (list[i].decisionNote != null)
                                list[i].decisionNote!,
                            ].join(' · '),
                            style: const TextStyle(fontSize: 12),
                          ),
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

class _DateField extends StatelessWidget {
  const _DateField({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final DateTime value;
  final ValueChanged<DateTime> onChanged;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(Radii.md),
      onTap: () async {
        final picked = await showDatePicker(
          context: context,
          initialDate: value,
          firstDate: DateTime(DateTime.now().year - 5),
          lastDate: DateTime(DateTime.now().year + 2),
        );
        if (picked != null) onChanged(picked);
      },
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: label,
          suffixIcon: const Icon(Icons.calendar_today_outlined, size: 18),
        ),
        child: Text(Fmt.date(value)),
      ),
    );
  }
}
