import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../hr/statutory_rates_tab.dart';
import 'contribution_table_paste.dart';

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

  /// The fields of this band whose text is not a number.
  ///
  /// Each of the four boxes used to read `double.tryParse(v) ?? 0`, and
  /// three of those zeros are caught downstream: a `wageFrom` of nought
  /// on a band that is not the lowest overlaps the one below it, and a
  /// `wageTo` that reads as null is an open-ended band in the middle --
  /// both refused by [rateTableProblem] and both asserted.
  ///
  /// The rate boxes are the ones with nothing behind them. Zero per
  /// cent is a LEGITIMATE band -- the lowest EPF band contributes
  /// nothing, and SOCSO's second category takes nothing from the
  /// employee -- so no downstream check can tell a deliberate nought
  /// from "11.5%" with the sign left on, or from a comma typed where a
  /// point was meant. Both of those published a schedule that deducts
  /// nothing from that wage band, on every payslip, until an audit.
  ///
  /// So the text is judged where it is typed, and a box that is not a
  /// number is remembered here rather than silently becoming one.
  final unreadable = <String>{};

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

/// Reads one box of a rate row, and refuses rather than substitutes.
///
/// [apply] is handed the figure, or null where the box is EMPTY -- which
/// means something different in each of the four boxes and is therefore
/// decided by the caller: an empty `From` is zero, an empty `To` is "and
/// over", an empty rate is no contribution.
///
/// What [apply] is never handed is a nought standing in for text nobody
/// could read. That goes on [RateDraft.unreadable] instead, where
/// [rateTableProblem] finds it and keeps the Publish button off.
///
/// Public, and next to [rateTableProblem] rather than inside the row
/// widget, for the reason that function is: the arithmetic of a
/// statutory schedule is the part worth asserting, and a private method
/// on a private `State` cannot be.
void readRateField(
  RateDraft rate,
  String field,
  String raw,
  void Function(double?) apply,
) {
  if (raw.trim().isEmpty) {
    rate.unreadable.remove(field);
    apply(null);
    return;
  }
  final value = Fmt.typedNumber(raw);
  if (value == null) {
    // Left where it was, deliberately. Clearing it to zero would be the
    // same silent substitution by another route, and the schedule
    // cannot be published while this is set anyway.
    rate.unreadable.add(field);
    return;
  }
  rate.unreadable.remove(field);
  apply(value);
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

  // Before any arithmetic, because arithmetic on a figure that was
  // never read is the thing being prevented. See `RateDraft.unreadable`.
  for (final r in rates) {
    if (r.unreadable.isNotEmpty) {
      final fields = r.unreadable.toList()..sort();
      return 'A band has something that is not a number in '
          '${fields.join(' and ')}.';
    }
  }

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

  /// Reads a table somebody pasted, and replaces the bands with it.
  ///
  /// Replaces rather than appends. A paste is the whole table — that is
  /// what makes it worth pasting — and adding it to whatever was typed
  /// first produces a set of bands that overlaps itself, which the
  /// check below would refuse with a message about the wrong thing.
  Future<void> _paste() async {
    final read = await showDialog<List<RateDraft>>(
      context: context,
      builder: (_) => const _PasteTableDialog(),
    );
    if (read == null || read.isEmpty || !mounted) return;
    setState(() {
      _rates
        ..clear()
        ..addAll(read);
      // A table of amounts is not a table of percentages, and the
      // method decides which the payroll engine reads. Pasting one and
      // leaving the method at `percentage` publishes a schedule whose
      // amounts are never looked at.
      _method = 'table';
    });
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
              Row(
                children: [
                  TextButton.icon(
                    onPressed: () => setState(() => _rates.add(RateDraft(
                          category: _rates.last.category,
                          wageFrom: _rates.last.wageTo ?? 0,
                        ))),
                    icon: const Icon(Icons.add, size: 18),
                    label: const Text('Add band'),
                  ),
                  const SizedBox(width: Space.sm),
                  // The reason a gazetted table has never been loaded.
                  // KWSP's Third Schedule runs to about ninety bands and
                  // PERKESO's to about seventy; typing them four boxes
                  // at a time is an afternoon, and nobody has had one.
                  TextButton.icon(
                    key: const ValueKey('paste-rate-table'),
                    onPressed: _paste,
                    icon: const Icon(Icons.content_paste, size: 18),
                    label: const Text('Paste a table'),
                  ),
                ],
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

  void _read(String raw, String field, void Function(double?) apply) {
    readRateField(widget.rate, field, raw, apply);
    widget.onChanged();
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
            onChanged: (v) => _read(v, 'From', (n) {
              // Empty is the lowest band starting where it has to.
              widget.rate.wageFrom = n ?? 0;
            }),
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
            onChanged: (v) => _read(v, 'To', (n) {
              // Empty is "and over", which the hint says and which only
              // the topmost band may be.
              widget.rate.wageTo = n;
            }),
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
            onChanged: (v) =>
                _read(v, 'Employee %', (n) => widget.rate.employeeRate = n ?? 0),
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
            onChanged: (v) =>
                _read(v, 'Employer %', (n) => widget.rate.employerRate = n ?? 0),
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

/// Pasting a gazetted contribution table in rather than typing it.
///
/// The parsing is in `contribution_table_paste.dart` and is pure; this
/// is the preview. What it shows before anything is accepted:
///
///   * **which column is which**, chosen rather than guessed, because
///     KWSP prints the employer first and most English reproductions
///     print the employee first — and read the wrong way round every
///     employee is deducted the employer's share, silently, on every
///     payslip;
///   * **every line that was not read**, in full rather than as a
///     count, because "read 88 of 91" tells nobody which three;
///   * **the first and last bands**, which is where a misread shows: a
///     table whose lowest band starts at five ringgit instead of five
///     thousand was read with the comma as a decimal point.
class _PasteTableDialog extends StatefulWidget {
  const _PasteTableDialog();

  @override
  State<_PasteTableDialog> createState() => _PasteTableDialogState();
}

class _PasteTableDialogState extends State<_PasteTableDialog> {
  final _text = TextEditingController();
  AmountColumns _order = AmountColumns.employeeFirst;
  ParsedTable? _parsed;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _read() {
    setState(() {
      _parsed = parseContributionTable(_text.text, order: _order);
    });
  }

  @override
  Widget build(BuildContext context) {
    final parsed = _parsed;
    final muted = Theme.of(
      context,
    ).textTheme.bodySmall?.copyWith(color: context.scheme.onSurfaceVariant);
    final warning = parsed == null ? null : columnOrderWarning(parsed, _order);

    return AlertDialog(
      title: const Text('Paste a contribution table'),
      content: SizedBox(
        width: 720,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Copy the table out of the authority’s own publication — '
                'KWSP’s Third Schedule, PERKESO’s Second Schedule — and '
                'paste it here. Nothing is filled in for you: every figure '
                'comes from what you paste, and a line that cannot be read '
                'is listed rather than guessed at.',
                key: const ValueKey('paste-table-note'),
                style: muted,
              ),
              const SizedBox(height: Space.md),
              DropdownButtonFormField<AmountColumns>(
                key: const ValueKey('paste-table-order'),
                isExpanded: true,
                value: _order,
                decoration: const InputDecoration(
                  labelText: 'Which amount column comes first',
                  helperText:
                      'KWSP prints the employer first. Getting this wrong '
                      'swaps every deduction with every contribution.',
                ),
                items: const [
                  DropdownMenuItem(
                    value: AmountColumns.employeeFirst,
                    child: Text('Employee, then employer'),
                  ),
                  DropdownMenuItem(
                    value: AmountColumns.employerFirst,
                    child: Text('Employer, then employee'),
                  ),
                ],
                onChanged: (v) {
                  if (v == null) return;
                  setState(() => _order = v);
                  if (_parsed != null) _read();
                },
              ),
              const SizedBox(height: Space.md),
              TextField(
                key: const ValueKey('paste-table-text'),
                controller: _text,
                minLines: 6,
                maxLines: 12,
                decoration: const InputDecoration(
                  labelText: 'The table',
                  alignLabelWithHint: true,
                ),
                onChanged: (_) {
                  if (_parsed != null) setState(() => _parsed = null);
                },
              ),
              const SizedBox(height: Space.sm),
              Align(
                alignment: Alignment.centerLeft,
                child: FilledButton.tonal(
                  key: const ValueKey('paste-table-read'),
                  onPressed: _text.text.trim().isEmpty ? null : _read,
                  child: const Text('Read it'),
                ),
              ),
              if (parsed != null) ...[
                const Divider(height: Space.xl),
                Text(
                  '${parsed.bands.length} '
                  'band${parsed.bands.length == 1 ? '' : 's'} read',
                  key: const ValueKey('paste-table-count'),
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                if (warning != null) ...[
                  const SizedBox(height: Space.sm),
                  Text(
                    warning,
                    key: const ValueKey('paste-table-order-warning'),
                    style: Theme.of(context).textTheme.bodySmall
                        ?.copyWith(color: context.colors.danger),
                  ),
                ],
                if (parsed.bands.isNotEmpty) ...[
                  const SizedBox(height: Space.sm),
                  // The ends, which is where a misread shows.
                  _Band('First', parsed.bands.first),
                  _Band('Last', parsed.bands.last),
                ],
                if (parsed.skipped.isNotEmpty) ...[
                  const SizedBox(height: Space.md),
                  Text(
                    'Not read:',
                    style: Theme.of(context).textTheme.titleSmall
                        ?.copyWith(color: context.colors.warning),
                  ),
                  for (final s in parsed.skipped)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        '${s.line}  —  ${s.because}',
                        style: muted,
                      ),
                    ),
                ],
              ],
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
          key: const ValueKey('paste-table-use'),
          onPressed: parsed == null || parsed.bands.isEmpty
              ? null
              : () => Navigator.pop(context, parsed.bands),
          child: const Text('Use these bands'),
        ),
      ],
    );
  }
}

class _Band extends StatelessWidget {
  const _Band(this.label, this.band);

  final String label;
  final RateDraft band;

  @override
  Widget build(BuildContext context) {
    final to = band.wageTo == null
        ? 'and over'
        : 'to ${Fmt.money(band.wageTo)}';
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Text(
        '$label: ${Fmt.money(band.wageFrom)} $to  ·  '
        'employee ${Fmt.money(band.employeeAmount)}  ·  '
        'employer ${Fmt.money(band.employerAmount)}',
        style: Theme.of(context).textTheme.bodySmall,
      ),
    );
  }
}
