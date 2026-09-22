import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/export_log.dart';
import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/skeletons.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/models.dart';
import '../../data/repository.dart';
import 'payment_file.dart';

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
          // The other half of a posted payroll: what it left the
          // company owing KWSP, PERKESO and LHDN, due on the fifteenth
          // of the following month. The badge is the point — a
          // contribution nobody was reminded of is the one that goes
          // late.
          if (canRun) const _RemittancesAction(),
          // And the other other half: the statement of remuneration
          // every employee is owed by the end of February, which is
          // what they file their own return from. Reached from here
          // because it is built out of the same posted runs.
          if (canRun)
            IconButton(
              tooltip: 'EA forms',
              onPressed: () => context.go('/hr/ea-forms'),
              icon: const Icon(Icons.description_outlined),
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
        skeleton: const ListSkeleton(rows: 6, leading: false),
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
      // Flexible, for the reason `_MatterTile` carries the same note:
      // a run number and a status chip are both natural-width, and the
      // box a ListTile gives its title is whatever the trailing left.
      // With a net-pay figure and "net pay" under it that is not much,
      // and the chip went 55 pixels off a 412px phone.
      title: Row(children: [
        Flexible(
          child: Text(run.runNo,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w600)),
        ),
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
        // A run's page is a header and the payslips under it, one row
        // to an employee. Which run was asked for does not change that
        // shape, only the names in it.
        skeleton: const Padding(
          padding: EdgeInsets.all(Space.lg),
          child: CardRowsSkeleton(
            rows: 6,
            leadingSize: 32,
            trailing: 1,
          ),
        ),
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
                  if (run.isPosted &&
                      ref.watch(canRunPayrollProvider)) ...[
                    _PaymentCard(run: run),
                    const SizedBox(height: Space.lg),
                  ],
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

/// Getting the money out.
///
/// Posting the run books the liability; it does not move a ringgit. This
/// turns the run into a file for the bank, shows anything that would stop
/// a line being paid, and — separately, once someone has actually put the
/// file through — records the run as paid.
class _PaymentCard extends ConsumerWidget {
  const _PaymentCard({required this.run});

  final PayrollRun run;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lines = ref.watch(paymentInstructionProvider(run.id));

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Space.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SectionHeader(
              run.status == 'paid' ? 'Paid' : 'Pay',
              subtitle: run.status == 'paid'
                  ? 'This run has been marked as paid'
                  : 'Posting booked the liability — this is the file that '
                      'moves the money',
            ),
            lines.when(
              loading: () => const LinearProgressIndicator(),
              error: (e, _) => Text('$e'),
              data: (list) => _PaymentBody(run: run, lines: list),
            ),
          ],
        ),
      ),
    );
  }
}

class _PaymentBody extends ConsumerWidget {
  const _PaymentBody({required this.run, required this.lines});

  final PayrollRun run;
  final List<PaymentLine> lines;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final payable = lines.where((l) => l.isPayable).toList();
    final held = lines.where((l) => !l.isPayable).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (held.isNotEmpty) _HeldNotice(held: held),
        for (var i = 0; i < lines.length; i++) ...[
          if (i > 0) const Divider(height: 1),
          _PaymentRow(line: lines[i]),
        ],
        const Divider(),
        Row(children: [
          Expanded(
            child: Text(
              '${payable.length} of ${lines.length} to pay',
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: context.scheme.onSurfaceVariant),
            ),
          ),
          Money(PaymentFile.total(lines), bold: true),
        ]),
        const SizedBox(height: Space.lg),
        Wrap(
          spacing: Space.sm,
          runSpacing: Space.sm,
          alignment: WrapAlignment.end,
          children: [
            OutlinedButton.icon(
              onPressed:
                  payable.isEmpty ? null : () => _export(context, ref, payable),
              icon: const Icon(Icons.download_outlined, size: 18),
              label: const Text('Payment file (CSV)'),
            ),
            if (run.status == 'posted')
              FilledButton.icon(
                onPressed:
                    payable.isEmpty ? null : () => _markPaid(context, ref),
                icon: const Icon(Icons.done_all, size: 18),
                label: const Text('Mark as paid'),
              ),
          ],
        ),
        const SizedBox(height: Space.sm),
        Text(
          'A generic CSV. Malaysian bank portals each want their own '
          'layout, so map the six columns once in the portal and reuse '
          'the mapping. Open it in a text editor rather than a '
          'spreadsheet, which will eat the leading zeros on account '
          'numbers.',
          style: Theme.of(context)
              .textTheme
              .bodySmall
              ?.copyWith(color: context.scheme.onSurfaceVariant),
        ),
      ],
    );
  }

  Future<void> _export(
    BuildContext context,
    WidgetRef ref,
    List<PaymentLine> payable,
  ) async {
    final csv = PaymentFile.csv(payable);
    final messenger = ScaffoldMessenger.of(context);
    final saved = await exportTextFile(
      ref,
      PaymentFile.filename(run.runNo),
      'text/csv',
      csv,
      what: 'Payroll bank file',
      detail: 'Run ${run.runNo}, ${payable.length} people',
    );
    if (!saved) {
      // Nothing downloads on a phone, so leave it somewhere the payer can
      // paste it rather than pretending the export happened.
      await Clipboard.setData(ClipboardData(text: csv));
    }
    messenger.showSnackBar(SnackBar(
      content: Text(saved
          ? '${payable.length} lines exported'
          : '${payable.length} lines copied to the clipboard'),
    ));
  }

  Future<void> _markPaid(BuildContext context, WidgetRef ref) async {
    final ok = await confirm(
      context,
      title: 'Mark ${run.runNo} as paid?',
      message: 'Do this once the bank has accepted the file. It records '
          'that the money went out; it does not send anything itself.',
      confirmLabel: 'Mark as paid',
    );
    if (!ok || !context.mounted) return;

    await runWithFeedback(
      context,
      action: () => ref.read(repoProvider)!.markPayrollPaid(run.id),
      successMessage: 'Marked as paid',
    );
    ref.invalidate(payrollRunsProvider);
    ref.invalidate(paymentInstructionProvider(run.id));
  }
}

/// Held lines are named before the file is offered, not after. The bank
/// will reject a whole batch over one bad row.
class _HeldNotice extends StatelessWidget {
  const _HeldNotice({required this.held});

  final List<PaymentLine> held;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: Space.md),
      padding: const EdgeInsets.all(Space.md),
      decoration: BoxDecoration(
        color: context.colors.warning.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(Radii.sm),
        border: Border.all(color: context.colors.warning.withValues(alpha: 0.4)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.warning_amber_rounded,
              size: 18, color: context.colors.warning),
          const SizedBox(width: Space.sm),
          Expanded(
            child: Text(
              '${held.length} ${held.length == 1 ? 'line is' : 'lines are'} '
              'held back and not in the file. Fix the employee record, then '
              'pay them separately.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}

class _PaymentRow extends StatelessWidget {
  const _PaymentRow({required this.line});

  final PaymentLine line;

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context)
        .textTheme
        .bodySmall
        ?.copyWith(color: context.scheme.onSurfaceVariant);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Space.sm),
      child: Row(children: [
        Expanded(
          flex: 3,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(line.employeeName,
                  style: const TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 2),
              if (line.problem != null)
                Text(line.problem!,
                    style: muted?.copyWith(color: context.colors.warning))
              else
                Text('${line.bankName} · ${line.bankAccountNo}', style: muted),
            ],
          ),
        ),
        Expanded(
          child: Money(
            line.amount,
            bold: line.isPayable,
            // A held line still shows its amount, greyed: the payer needs
            // to know how much is not going out.
            style: line.isPayable
                ? null
                : Theme.of(context)
                    .textTheme
                    .bodyMedium
                    ?.copyWith(color: context.scheme.onSurfaceVariant),
          ),
        ),
      ]),
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
              isExpanded: true,
              initialValue: _month,
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
              isExpanded: true,
              initialValue: _year,
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


/// The way to what a posted payroll still owes, with a mark on it when
/// something is overdue.
class _RemittancesAction extends ConsumerWidget {
  const _RemittancesAction();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final due = ref.watch(statutoryDueProvider).valueOrNull ?? const [];
    final overdue = due.where((d) => d['is_overdue'] == true).length;

    return IconButton(
      tooltip: overdue > 0
          ? '$overdue statutory contribution'
                '${overdue == 1 ? '' : 's'} overdue'
          : 'Statutory remittances',
      onPressed: () => context.go('/hr/remittances'),
      icon: Badge(
        isLabelVisible: due.isNotEmpty,
        backgroundColor: overdue > 0 ? context.colors.danger : null,
        label: Text('${due.length}'),
        child: const Icon(Icons.account_balance_outlined),
      ),
    );
  }
}
