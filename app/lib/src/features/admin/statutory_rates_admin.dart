import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../hr/statutory_rates_tab.dart';

/// Publishing the EPF, SOCSO, EIS, PCB and HRD Corp rate tables.
///
/// This lives in the platform console and nowhere else. The tables have
/// no `org_id`: there is one set of them for the whole database, so a
/// figure changed here changes every company's payroll on the next run.
/// The database enforces that with `app.is_platform_admin()`; this
/// screen only makes it reachable.
///
/// The seeded figures are all `is_verified = false`, which is the
/// database saying nobody has checked them against the gazette. Marking
/// one verified is a separate act from typing it, deliberately: one
/// person enters the numbers and another confirms them against the
/// KWSP or PERKESO table.
class StatutoryRatesAdminTab extends ConsumerWidget {
  const StatutoryRatesAdminTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final schedules = ref.watch(statutorySchedulesProvider);

    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _publish(context, ref),
        icon: const Icon(Icons.publish),
        label: const Text('Publish rates'),
      ),
      body: AsyncView(
        value: schedules,
        onRetry: () => ref.invalidate(statutorySchedulesProvider),
        builder: (list) => ListView(
          padding: const EdgeInsets.only(bottom: 96),
          children: [
            const Padding(
              padding: EdgeInsets.all(Space.lg),
              child: WarningPanel(
                text: 'These tables are shared by every organization in the '
                    'database. Publishing a schedule changes what the next '
                    'payroll run calculates, everywhere, for everybody.',
              ),
            ),
            for (final s in list)
              Padding(
                padding:
                    const EdgeInsets.fromLTRB(Space.lg, 0, Space.lg, Space.sm),
                child: _AdminScheduleTile(schedule: s),
              ),
          ],
        ),
      ),
    );
  }

  static Future<void> _publish(BuildContext context, WidgetRef ref) async {
    final done = await showDialog<bool>(
      context: context,
      builder: (_) => const _PublishDialog(),
    );
    if (done == true) ref.invalidate(statutorySchedulesProvider);
  }
}

class _AdminScheduleTile extends ConsumerWidget {
  const _AdminScheduleTile({required this.schedule});

  final Map<String, dynamic> schedule;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final verified = schedule['is_verified'] == true;
    final rates = (schedule['statutory_rates'] as List?)?.length ?? 0;
    final from = Fmt.parseDate(schedule['effective_from']);
    final to = Fmt.parseDate(schedule['effective_to']);

    return Card(
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(
            horizontal: Space.lg, vertical: Space.xs),
        title: Row(children: [
          Flexible(
            child: Text(
              '${Fmt.label(schedule['body']?.toString() ?? '')} · '
              '${schedule['name']}',
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
          const SizedBox(width: Space.sm),
          StatusChip(verified ? 'verified' : 'unverified', compact: true),
        ]),
        subtitle: Text(
          [
            to == null
                ? 'in force from ${Fmt.date(from)}'
                : '${Fmt.date(from)} to ${Fmt.date(to)}',
            '$rates band${rates == 1 ? '' : 's'}',
            if (schedule['source'] != null) schedule['source'].toString(),
          ].join(' · '),
          style: const TextStyle(fontSize: 12),
        ),
        trailing: TextButton(
          onPressed: () => _toggle(context, ref, !verified),
          child: Text(verified ? 'Unverify' : 'Mark verified'),
        ),
      ),
    );
  }

  Future<void> _toggle(BuildContext context, WidgetRef ref, bool to) async {
    if (to) {
      final ok = await confirm(
        context,
        title: 'Confirm against the gazette?',
        message: 'Marking this verified tells every organization these are '
            'the published figures and that returns may be filed on them. '
            'Only do it having compared them to the source table.',
        confirmLabel: 'Mark verified',
      );
      if (!ok || !context.mounted) return;
    }

    await runWithFeedback(
      context,
      action: () => ref
          .read(platformRepoProvider)
          .setScheduleVerified(schedule['id'] as String, to),
      successMessage: to ? 'Marked verified' : 'Marked unverified',
    );
    ref.invalidate(statutorySchedulesProvider);
  }
}

/// One band of a rate table being typed in.
class RateDraft {
  RateDraft({
    this.category = 'default',
    this.wageFrom = 0,
    this.wageTo,
    this.employeeRate = 0,
    this.employerRate = 0,
    this.employeeAmount,
    this.employerAmount,
    this.wageCeiling,
  });

  String category;
  double wageFrom;
  double? wageTo;
  double employeeRate;
  double employerRate;
  double? employeeAmount;
  double? employerAmount;
  double? wageCeiling;

  Map<String, dynamic> toJson() => {
        'category': category,
        'wage_from': wageFrom,
        if (wageTo != null) 'wage_to': wageTo,
        'employee_rate': employeeRate,
        'employer_rate': employerRate,
        if (employeeAmount != null) 'employee_amount': employeeAmount,
        if (employerAmount != null) 'employer_amount': employerAmount,
        if (wageCeiling != null) 'wage_ceiling': wageCeiling,
      };
}

/// What is wrong with a set of bands, or null if nothing is.
///
/// The database refuses an empty schedule and an unknown rounding mode.
/// These are the mistakes it would accept: a band that ends before it
/// starts, and a gap or overlap between consecutive bands, both of
/// which produce a wage that lands in no band and a deduction of zero
/// on somebody's payslip.
String? rateTableProblem(List<RateDraft> rates) {
  if (rates.isEmpty) return 'A schedule needs at least one band.';

  final byCategory = <String, List<RateDraft>>{};
  for (final r in rates) {
    if (r.wageTo != null && r.wageTo! < r.wageFrom) {
      return 'A band ends below where it starts.';
    }
    if (r.wageFrom < 0) return 'A band cannot start below zero.';
    byCategory.putIfAbsent(r.category, () => []).add(r);
  }

  for (final entry in byCategory.entries) {
    final bands = [...entry.value]..sort((a, b) => a.wageFrom.compareTo(b.wageFrom));
    if (bands.first.wageFrom > 0) {
      return 'The ${entry.key} bands start above zero, so the lowest wages '
          'fall outside every band.';
    }
    for (var i = 0; i < bands.length - 1; i++) {
      final end = bands[i].wageTo;
      if (end == null) {
        return 'A ${entry.key} band with no upper limit is not the last one.';
      }
      if ((bands[i + 1].wageFrom - end).abs() > 0.011) {
        return 'The ${entry.key} bands leave a gap or overlap around '
            '${Fmt.money(end)}.';
      }
    }
    if (bands.last.wageTo != null) {
      return 'The top ${entry.key} band needs no upper limit, or a wage above '
          'it falls outside every band.';
    }
  }
  return null;
}

class _PublishDialog extends ConsumerStatefulWidget {
  const _PublishDialog();

  @override
  ConsumerState<_PublishDialog> createState() => _PublishDialogState();
}

class _PublishDialogState extends ConsumerState<_PublishDialog> {
  final _name = TextEditingController();
  final _source = TextEditingController();

  String _body = 'epf';
  String _method = 'percentage';
  String _rounding = 'nearest_cent';
  DateTime _from = DateTime(DateTime.now().year + 1, 1, 1);
  bool _verified = false;
  bool _saving = false;

  final List<RateDraft> _rates = [RateDraft()];

  @override
  void dispose() {
    _name.dispose();
    _source.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final problem = rateTableProblem(_rates);

    return AlertDialog(
      title: const Text('Publish a rate table'),
      content: SizedBox(
        width: 720,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(children: [
                Expanded(
                  child: DropdownButtonFormField<String>(
                    value: _body,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: 'Body'),
                    items: const [
                      DropdownMenuItem(value: 'epf', child: Text('EPF (KWSP)')),
                      DropdownMenuItem(
                          value: 'socso', child: Text('SOCSO (PERKESO)')),
                      DropdownMenuItem(value: 'eis', child: Text('EIS')),
                      DropdownMenuItem(value: 'pcb', child: Text('PCB / MTD')),
                      DropdownMenuItem(
                          value: 'hrdf', child: Text('HRD Corp levy')),
                    ],
                    onChanged: (v) => setState(() => _body = v ?? 'epf'),
                  ),
                ),
                const SizedBox(width: Space.md),
                Expanded(
                  child: InkWell(
                    onTap: () async {
                      final picked = await showDatePicker(
                        context: context,
                        initialDate: _from,
                        firstDate: DateTime(2000),
                        lastDate: DateTime(2100),
                        helpText: 'In force from',
                      );
                      if (picked != null) setState(() => _from = picked);
                    },
                    child: InputDecorator(
                      decoration: const InputDecoration(
                        labelText: 'In force from',
                        helperText: 'Closes the schedule it supersedes',
                        suffixIcon: Icon(Icons.calendar_today, size: 18),
                      ),
                      child: Text(Fmt.date(_from)),
                    ),
                  ),
                ),
              ]),
              const SizedBox(height: Space.md),
              TextField(
                controller: _name,
                decoration: const InputDecoration(
                  labelText: 'Name *',
                  hintText: 'EPF statutory rates from 2027',
                ),
              ),
              const SizedBox(height: Space.md),
              TextField(
                controller: _source,
                decoration: const InputDecoration(
                  labelText: 'Source',
                  hintText: 'KWSP Third Schedule, effective 1 January 2027',
                ),
              ),
              const SizedBox(height: Space.md),
              Row(children: [
                Expanded(
                  child: DropdownButtonFormField<String>(
                    value: _method,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: 'Method'),
                    items: const [
                      DropdownMenuItem(
                          value: 'percentage', child: Text('Percentage')),
                      DropdownMenuItem(
                          value: 'table', child: Text('Table of amounts')),
                    ],
                    onChanged: (v) => setState(() => _method = v ?? 'percentage'),
                  ),
                ),
                const SizedBox(width: Space.md),
                Expanded(
                  child: DropdownButtonFormField<String>(
                    value: _rounding,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: 'Rounding'),
                    items: const [
                      DropdownMenuItem(
                          value: 'nearest_cent', child: Text('Nearest cent')),
                      DropdownMenuItem(
                          value: 'nearest_5sen', child: Text('Nearest 5 sen')),
                      DropdownMenuItem(
                          value: 'up_ringgit', child: Text('Up to the ringgit')),
                    ],
                    onChanged: (v) =>
                        setState(() => _rounding = v ?? 'nearest_cent'),
                  ),
                ),
              ]),
              const Divider(height: Space.xl),
              for (var i = 0; i < _rates.length; i++)
                _RateRow(
                  key: ObjectKey(_rates[i]),
                  rate: _rates[i],
                  onChanged: () => setState(() {}),
                  onRemove: _rates.length > 1
                      ? () => setState(() => _rates.removeAt(i))
                      : null,
                ),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () => setState(() => _rates.add(RateDraft(
                        category: _rates.last.category,
                        wageFrom: _rates.last.wageTo ?? 0,
                      ))),
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('Add band'),
                ),
              ),
              if (problem != null)
                Text(problem,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: context.colors.warning,
                    )),
              const SizedBox(height: Space.sm),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: _verified,
                onChanged: (v) => setState(() => _verified = v),
                title: const Text('I have checked these against the source'),
                subtitle: const Text(
                    'Leave off and the schedule is published as unverified'),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _saving || problem != null ? null : _save,
          child: _saving
              ? const SizedBox(
                  height: 18,
                  width: 18,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('Publish'),
        ),
      ],
    );
  }

  Future<void> _save() async {
    if (_name.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Give the schedule a name'),
      ));
      return;
    }

    final ok = await confirm(
      context,
      title: 'Publish to every organization?',
      message: 'From ${Fmt.date(_from)} every payroll run in the database '
          'calculates ${Fmt.label(_body)} with these figures.',
      confirmLabel: 'Publish',
    );
    if (!ok || !mounted) return;

    setState(() => _saving = true);
    final done = await runWithFeedback(
      context,
      action: () => ref.read(platformRepoProvider).publishStatutorySchedule(
            body: _body,
            name: _name.text.trim(),
            method: _method,
            effectiveFrom: _from,
            rates: [for (final r in _rates) r.toJson()],
            source: _source.text.trim().isEmpty ? null : _source.text.trim(),
            resultRounding: _rounding,
            isVerified: _verified,
          ),
      successMessage: 'Published',
      pendingMessage: 'Publishing…',
    );

    if (mounted) setState(() => _saving = false);
    if (done && mounted) Navigator.pop(context, true);
  }
}

class _RateRow extends StatefulWidget {
  const _RateRow({
    super.key,
    required this.rate,
    required this.onChanged,
    this.onRemove,
  });

  final RateDraft rate;
  final VoidCallback onChanged;
  final VoidCallback? onRemove;

  @override
  State<_RateRow> createState() => _RateRowState();
}

class _RateRowState extends State<_RateRow> {
  late final _category = TextEditingController(text: widget.rate.category);
  late final _from =
      TextEditingController(text: widget.rate.wageFrom.toStringAsFixed(2));
  late final _to =
      TextEditingController(text: widget.rate.wageTo?.toStringAsFixed(2) ?? '');
  late final _employee =
      TextEditingController(text: widget.rate.employeeRate.toString());
  late final _employer =
      TextEditingController(text: widget.rate.employerRate.toString());

  @override
  void dispose() {
    _category.dispose();
    _from.dispose();
    _to.dispose();
    _employee.dispose();
    _employer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(
          flex: 2,
          child: TextField(
            controller: _category,
            decoration:
                const InputDecoration(isDense: true, labelText: 'Category'),
            onChanged: (v) {
              widget.rate.category = v.trim().isEmpty ? 'default' : v.trim();
              widget.onChanged();
            },
          ),
        ),
        const SizedBox(width: 8),
        SizedBox(
          width: 110,
          child: TextField(
            controller: _from,
            textAlign: TextAlign.right,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(isDense: true, labelText: 'From'),
            onChanged: (v) {
              widget.rate.wageFrom = double.tryParse(v) ?? 0;
              widget.onChanged();
            },
          ),
        ),
        const SizedBox(width: 8),
        SizedBox(
          width: 110,
          child: TextField(
            controller: _to,
            textAlign: TextAlign.right,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(
                isDense: true, labelText: 'To', hintText: 'and over'),
            onChanged: (v) {
              widget.rate.wageTo = v.trim().isEmpty ? null : double.tryParse(v);
              widget.onChanged();
            },
          ),
        ),
        const SizedBox(width: 8),
        SizedBox(
          width: 100,
          child: TextField(
            controller: _employee,
            textAlign: TextAlign.right,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration:
                const InputDecoration(isDense: true, labelText: 'Employee %'),
            onChanged: (v) {
              widget.rate.employeeRate = double.tryParse(v) ?? 0;
              widget.onChanged();
            },
          ),
        ),
        const SizedBox(width: 8),
        SizedBox(
          width: 100,
          child: TextField(
            controller: _employer,
            textAlign: TextAlign.right,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration:
                const InputDecoration(isDense: true, labelText: 'Employer %'),
            onChanged: (v) {
              widget.rate.employerRate = double.tryParse(v) ?? 0;
              widget.onChanged();
            },
          ),
        ),
        IconButton(
          icon: const Icon(Icons.close, size: 18),
          onPressed: widget.onRemove,
        ),
      ]),
    );
  }
}
