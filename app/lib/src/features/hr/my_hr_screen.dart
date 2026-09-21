import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/export_log.dart';
import '../../core/format.dart';
import '../../core/pdf_kit.dart' show LetterheadMode;
import '../../core/providers.dart';
import '../../core/skeletons.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/ea_form_repository.dart';
import '../../data/models.dart';
import '../../data/repository.dart';
import 'attendance_month.dart';
import 'ea_form_pdf.dart';

/// Self-service. Everything here is scoped to the person signed in, and
/// the scoping is the database's job — an employee simply cannot read
/// anyone else's rows, whatever this screen asks for.
class MyHrScreen extends ConsumerWidget {
  const MyHrScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final me = ref.watch(myEmployeeProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('My HR')),
      body: AsyncView(
        value: me,
        onRetry: () => ref.invalidate(myEmployeeProvider),
        // The self-service cards -- clock, leave, payslips, claims --
        // are the same cards for everybody. What is waiting is which
        // employee they belong to.
        skeleton: const Padding(
          padding: EdgeInsets.all(Space.lg),
          child: CardRowsSkeleton(
            rows: 4,
            leadingSize: 24,
            trailing: 1,
            rowGap: Space.lg,
          ),
        ),
        builder: (employee) {
          if (employee == null) {
            return const EmptyState(
              icon: Icons.badge_outlined,
              title: 'No employee record',
              message: 'Your login is not linked to an employee record yet. '
                  'Ask HR to connect them and self-service will appear here.',
            );
          }
          return SingleChildScrollView(
            child: PageBody(
              maxWidth: 1000,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _ClockCard(employee: employee),
                  const SizedBox(height: Space.lg),
                  _LeaveBalancesCard(employee: employee),
                  const SizedBox(height: Space.lg),
                  _MyPayslipsCard(employee: employee),
                  const SizedBox(height: Space.lg),
                  _MyEaFormCard(employee: employee),
                  const SizedBox(height: Space.lg),
                  _MyDetailsCard(employee: employee),
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

class _ClockCard extends ConsumerWidget {
  const _ClockCard({required this.employee});

  final Employee employee;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final today = ref.watch(myAttendanceTodayProvider);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Space.lg),
        child: today.when(
          // The card is an icon, two lines and the controls at the
          // end whatever the punch says; only which words and which
          // button are waiting on the record.
          loading: () => const CardRowsSkeleton(
              leadingSize: 48, trailing: 2, trailingWidth: 56, rowGap: 0),
          error: (e, _) => Text('$e'),
          data: (record) {
            final clockedIn = record?.clockIn != null && record?.clockOut == null;
            final done = record?.clockOut != null;

            return Row(children: [
              Container(
                padding: const EdgeInsets.all(Space.md),
                decoration: BoxDecoration(
                  color: (done
                          ? context.colors.success
                          : clockedIn
                              ? context.colors.info
                              : context.scheme.onSurfaceVariant)
                      .withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(Radii.md),
                ),
                child: Icon(
                  done
                      ? Icons.check_circle_outline
                      : clockedIn
                          ? Icons.timer_outlined
                          : Icons.schedule,
                  color: done
                      ? context.colors.success
                      : clockedIn
                          ? context.colors.info
                          : context.scheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(width: Space.lg),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      done
                          ? 'Done for today'
                          : clockedIn
                              ? 'Clocked in'
                              : 'Not clocked in',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      record == null
                          ? Fmt.longDate(DateTime.now())
                          : [
                              if (record.clockIn != null)
                                'In ${Fmt.time(record.clockIn)}',
                              if (record.clockOut != null)
                                'Out ${Fmt.time(record.clockOut)}',
                              if (record.workedMinutes > 0)
                                '${(record.workedMinutes / 60).toStringAsFixed(1)} h',
                              if (record.lateMinutes > 0)
                                '${record.lateMinutes} min late',
                            ].join(' · '),
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              // The month behind today. The card has only ever shown
              // the current day, so nobody could check their own
              // attendance before payroll ran on it.
              IconButton(
                key: const ValueKey('my-attendance-month'),
                tooltip: 'This month',
                icon: const Icon(Icons.calendar_month_outlined),
                onPressed: () => showAttendanceMonth(
                  context,
                  employeeId: employee.id,
                  name: 'You',
                ),
              ),
              if (!done)
                FilledButton.icon(
                  onPressed: () => _punch(context, ref, clockedIn),
                  icon: Icon(clockedIn ? Icons.logout : Icons.login, size: 18),
                  label: Text(clockedIn ? 'Clock out' : 'Clock in'),
                ),
            ]);
          },
        ),
      ),
    );
  }

  Future<void> _punch(BuildContext context, WidgetRef ref, bool out) async {
    final repo = ref.read(repoProvider)!;
    await runWithFeedback(
      context,
      action: () async => out ? await repo.clockOut() : await repo.clockIn(),
      successMessage: out ? 'Clocked out' : 'Clocked in',
    );
    ref.invalidate(myAttendanceTodayProvider);
  }
}

class _LeaveBalancesCard extends ConsumerWidget {
  const _LeaveBalancesCard({required this.employee});

  final Employee employee;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final balances = ref.watch(myLeaveBalancesProvider);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Space.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SectionHeader(
              'Leave balance',
              subtitle: 'Days remaining in ${DateTime.now().year}',
              action: TextButton(
                onPressed: () => context.go('/hr/leave'),
                child: const Text('Request leave'),
              ),
            ),
            balances.when(
              loading: () => const LinearProgressIndicator(),
              error: (e, _) => Text('$e'),
              data: (list) => list.isEmpty
                  ? Text('No leave entitlement has been set up yet.',
                      style: Theme.of(context).textTheme.bodySmall)
                  : Wrap(
                      spacing: Space.md,
                      runSpacing: Space.md,
                      children: [
                        for (final b in list)
                          _BalancePill(balance: b),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _BalancePill extends StatelessWidget {
  const _BalancePill({required this.balance});

  final LeaveBalance balance;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 168,
      padding: const EdgeInsets.all(Space.md),
      decoration: BoxDecoration(
        color: context.scheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(Radii.md),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(balance.leaveTypeName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: Space.xs),
          Text(Fmt.days(balance.available),
              style: Theme.of(context)
                  .textTheme
                  .headlineSmall
                  ?.copyWith(fontWeight: FontWeight.w700)),
          Text(
            '${Fmt.days(balance.taken)} taken'
            '${balance.pending > 0 ? ' · ${Fmt.days(balance.pending)} pending' : ''}',
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: context.scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

class _MyPayslipsCard extends ConsumerWidget {
  const _MyPayslipsCard({required this.employee});

  final Employee employee;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final payslips = ref.watch(myPayslipsProvider);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Space.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SectionHeader('My payslips',
                subtitle: 'Only you and payroll can see these'),
            payslips.when(
              loading: () => const LinearProgressIndicator(),
              error: (e, _) => Text('$e'),
              data: (list) => list.isEmpty
                  ? Text('No payslip has been issued yet.',
                      style: Theme.of(context).textTheme.bodySmall)
                  : Column(
                      children: [
                        for (var i = 0; i < list.length; i++) ...[
                          if (i > 0) const Divider(height: 1),
                          ListTile(
                            contentPadding: EdgeInsets.zero,
                            onTap: () => context.go('/hr/payslip/${list[i].id}'),
                            title: Text(list[i].periodCode ?? '—',
                                style: const TextStyle(
                                    fontWeight: FontWeight.w600)),
                            subtitle: Text(
                                'Gross ${Fmt.money(list[i].grossPay)}',
                                style: const TextStyle(fontSize: 12)),
                            trailing: Money(list[i].netPay, bold: true),
                          ),
                        ],
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The employee's own EA form.
///
/// `0608` allows the payroll administrator OR the employee themselves to
/// read one, which is exactly the `payslips` policy — an EA form is a
/// year of payslips added up, and somebody entitled to twelve of those
/// is entitled to their total.
///
/// The year offered is the one that has ENDED. An EA form is issued in
/// February for the year before; offering the current one would produce
/// a part-year form somebody might try to file.
class _MyEaFormCard extends ConsumerStatefulWidget {
  const _MyEaFormCard({required this.employee});

  final Employee employee;

  @override
  ConsumerState<_MyEaFormCard> createState() => _MyEaFormCardState();
}

class _MyEaFormCardState extends ConsumerState<_MyEaFormCard> {
  late int _year = DateTime.now().year - 1;
  bool _busy = false;

  List<int> get _years {
    final now = DateTime.now().year;
    return [for (var y = now - 1; y >= now - 6; y--) y];
  }

  Future<void> _download() async {
    final messenger = ScaffoldMessenger.of(context);
    final org = ref.read(currentOrgProvider).valueOrNull;
    final repo = ref.read(eaFormsRepoProvider);
    if (org == null || repo == null) return;

    setState(() => _busy = true);
    try {
      final ea = await repo.statement(widget.employee.id, _year);
      if (ea.monthsPaid == 0) {
        messenger.showSnackBar(
          SnackBar(
            content: Text(
              'You were not paid anything in $_year. An EA form covers '
              'what was PAID in a year, so a December salary paid in '
              'January belongs to the following one.',
            ),
          ),
        );
        return;
      }
      final bytes = await buildEaFormPdf(
        org: org,
        ea: ea,
        logo: await ref.read(orgLogoProvider.future),
        mode: org.usesPreprintedLetterhead
            ? LetterheadMode.stationery
            : LetterheadMode.printed,
      );
      final saved = await exportBytesFile(
        ref,
        'ea-$_year.pdf',
        'application/pdf',
        bytes,
        what: 'EA form',
        detail: '$_year',
      );
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            saved
                ? 'Downloaded'
                : 'PDF download is only available in the browser',
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Space.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SectionHeader(
              'My EA form',
              subtitle: 'What to file your own tax return from',
            ),
            const SizedBox(height: Space.sm),
            Row(
              children: [
                DropdownButton<int>(
                  key: const ValueKey('my-ea-year'),
                  value: _year,
                  items: [
                    for (final y in _years)
                      DropdownMenuItem(value: y, child: Text('$y')),
                  ],
                  onChanged: _busy
                      ? null
                      : (v) => setState(() => _year = v ?? _year),
                ),
                const SizedBox(width: Space.lg),
                FilledButton.icon(
                  key: const ValueKey('my-ea-download'),
                  onPressed: _busy ? null : _download,
                  icon: const Icon(Icons.download_outlined, size: 18),
                  label: const Text('Download'),
                ),
              ],
            ),
            const SizedBox(height: Space.sm),
            Text(
              'Covers what you were PAID in the year, not what you earned '
              'in it — a December salary paid in January is on the '
              'following year\'s form. If you had another job in the same '
              'year, that employer issues their own and you declare both.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: context.scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MyDetailsCard extends StatelessWidget {
  const _MyDetailsCard({required this.employee});

  final Employee employee;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Space.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SectionHeader('My details',
                subtitle: 'Ask HR to correct anything that is wrong'),
            for (final row in <(String, String)>[
              ('Employee number', employee.employeeNo),
              ('Position', employee.positionTitle ?? '—'),
              ('Department', employee.departmentName ?? '—'),
              ('Joined', Fmt.date(employee.hireDate)),
              ('EPF number', employee.epfNo ?? '—'),
              ('SOCSO number', employee.socsoNo ?? '—'),
              ('Income tax file', employee.incomeTaxNo ?? '—'),
              ('Salary credited to',
                  [employee.bankName, employee.bankAccountNo]
                      .where((e) => e != null && e.isNotEmpty)
                      .join(' · ')),
            ])
              Padding(
                padding: const EdgeInsets.symmetric(vertical: Space.xs),
                child: Row(children: [
                  SizedBox(
                    width: 170,
                    child: Text(row.$1,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: context.scheme.onSurfaceVariant)),
                  ),
                  Expanded(
                    child: Text(row.$2.isEmpty ? '—' : row.$2,
                        style: Theme.of(context).textTheme.bodyMedium),
                  ),
                ]),
              ),
          ],
        ),
      ),
    );
  }
}
