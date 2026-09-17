import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/models.dart';
import '../../data/repository.dart';

/// The tax year an employee brings with them.
///
/// PCB is computed by projecting the year, so an employee who joined in
/// July with nothing recorded here has six months of pay projected as if
/// it were the whole year. On RM8,000 a month that is RM32 deducted
/// where RM769.95 is due — the shortfall lands on the employee at
/// filing, and on whoever prepared the payroll.
///
/// Saved on its own rather than with the rest of the form: these are
/// separate records, and an accidental Save on the employee form should
/// not silently rewrite what a previous employer paid.
class TaxYearSection extends ConsumerStatefulWidget {
  const TaxYearSection({super.key, required this.employeeId});

  final String employeeId;

  @override
  ConsumerState<TaxYearSection> createState() => _TaxYearSectionState();
}

class _TaxYearSectionState extends ConsumerState<TaxYearSection> {
  final _c = <String, TextEditingController>{};
  bool _loaded = false;
  bool _saving = false;

  int get _year => DateTime.now().year;

  TextEditingController _ctl(String key) =>
      _c.putIfAbsent(key, () => TextEditingController());

  @override
  void dispose() {
    for (final c in _c.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _hydrate(YtdOpening? opening) {
    if (_loaded) return;
    _loaded = true;
    if (opening == null) return;
    void set(String key, double v) =>
        _ctl(key).text = v == 0 ? '' : v.toStringAsFixed(2);
    set('gross_pay', opening.grossPay);
    set('epf_employee', opening.epfEmployee);
    set('pcb_paid', opening.pcbPaid);
    set('zakat_paid', opening.zakatPaid);
    set('benefits_in_kind', opening.benefitsInKind);
    _ctl('notes').text = opening.notes ?? '';
  }

  @override
  Widget build(BuildContext context) {
    final opening = ref.watch(ytdOpeningProvider(widget.employeeId));
    final reliefs = ref.watch(declaredReliefsProvider(widget.employeeId));

    return Padding(
      padding: const EdgeInsets.only(bottom: Space.lg),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(Space.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SectionHeader(
                'Tax year $_year',
                subtitle: 'What they brought with them, and what they have '
                    'declared. Both change the PCB.',
              ),
              AsyncView(
                value: opening,
                onRetry: () =>
                    ref.invalidate(ytdOpeningProvider(widget.employeeId)),
                loading: const LinearProgressIndicator(),
                builder: (o) {
                  _hydrate(o);
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        'Leave these at nil for anyone employed here since '
                        '1 January. For a mid-year joiner, copy the totals '
                        'from their last payslip or the EA form from their '
                        'previous employer — without them the year is '
                        'projected from a part year and the deduction comes '
                        'out far too low.',
                        style: Theme.of(context)
                            .textTheme
                            .bodySmall
                            ?.copyWith(color: context.scheme.onSurfaceVariant),
                      ),
                      const SizedBox(height: Space.md),
                      _pair([
                        _money('gross_pay', 'Gross pay already earned'),
                        _money('epf_employee', 'EPF already deducted'),
                      ]),
                      _pair([
                        _money('pcb_paid', 'PCB already paid'),
                        _money('zakat_paid', 'Zakat already paid'),
                      ]),
                      _pair([
                        _money('benefits_in_kind', 'Benefits in kind',
                            helper: 'Perquisites and BIK, which are income'),
                        const SizedBox.shrink(),
                      ]),
                      Padding(
                        padding: const EdgeInsets.only(top: Space.md),
                        child: TextField(
                          controller: _ctl('notes'),
                          decoration: const InputDecoration(
                            labelText: 'Where these figures came from',
                            helperText: 'The auditor will ask',
                          ),
                        ),
                      ),
                      const SizedBox(height: Space.md),
                      Align(
                        alignment: Alignment.centerRight,
                        child: FilledButton.tonal(
                          onPressed: _saving ? null : _saveOpening,
                          child: const Text('Save opening figures'),
                        ),
                      ),
                      const Divider(height: Space.xxl),
                      _ReliefList(
                        employeeId: widget.employeeId,
                        taxYear: _year,
                        reliefs: reliefs,
                      ),
                    ],
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _pair(List<Widget> children) => Padding(
        padding: const EdgeInsets.only(top: Space.md),
        child: LayoutBuilder(
          builder: (context, box) => box.maxWidth < 560
              ? Column(children: [
                  for (var i = 0; i < children.length; i++) ...[
                    if (i > 0) const SizedBox(height: Space.md),
                    children[i],
                  ],
                ])
              : Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (var i = 0; i < children.length; i++) ...[
                      if (i > 0) const SizedBox(width: Space.md),
                      Expanded(child: children[i]),
                    ],
                  ],
                ),
        ),
      );

  Widget _money(String key, String label, {String? helper}) => TextField(
        controller: _ctl(key),
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: InputDecoration(
          labelText: label,
          prefixText: 'RM ',
          helperText: helper,
        ),
      );

  double _num(String key) => double.tryParse(_ctl(key).text.trim()) ?? 0;

  Future<void> _saveOpening() async {
    setState(() => _saving = true);
    await runWithFeedback(
      context,
      action: () => ref.read(repoProvider)!.saveYtdOpening(
            widget.employeeId,
            YtdOpening(
              taxYear: _year,
              grossPay: _num('gross_pay'),
              epfEmployee: _num('epf_employee'),
              pcbPaid: _num('pcb_paid'),
              zakatPaid: _num('zakat_paid'),
              benefitsInKind: _num('benefits_in_kind'),
              notes: _ctl('notes').text.trim().isEmpty
                  ? null
                  : _ctl('notes').text.trim(),
            ),
          ),
      successMessage: 'Opening figures saved — they apply from the next run',
    );
    if (mounted) setState(() => _saving = false);
    ref.invalidate(ytdOpeningProvider(widget.employeeId));
  }
}

/// Reliefs the employee has declared on a TP1. Everything the company
/// can work out for itself — the individual allowance, EPF, SOCSO, the
/// spouse and the children on file — is applied automatically and is
/// deliberately absent from this list.
class _ReliefList extends ConsumerWidget {
  const _ReliefList({
    required this.employeeId,
    required this.taxYear,
    required this.reliefs,
  });

  final String employeeId;
  final int taxYear;
  final AsyncValue<List<DeclaredRelief>> reliefs;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final typesAsync = ref.watch(reliefTypesProvider(taxYear));
    final types = typesAsync.valueOrNull ?? const <ReliefType>[];
    final byCode = {for (final t in types) t.code: t};

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionHeader(
          'Declared reliefs',
          subtitle: 'From the employee’s TP1. Reliefs the company already '
              'knows about are applied without being listed here.',
          action: TextButton.icon(
            onPressed: types.isEmpty
                ? null
                : () => _edit(context, ref, types, null),
            icon: const Icon(Icons.add, size: 18),
            label: const Text('Add'),
          ),
        ),
        // Why the Add button is off, when it is off. Without this the
        // list failing to load and LHDN having published nothing look
        // identical from the outside — a greyed-out button and no
        // reason — which is how a broken column name went unnoticed for
        // the whole life of this screen.
        if (types.isEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: Space.sm),
            child: Text(
              typesAsync.hasError
                  ? 'The list of reliefs could not be loaded, so nothing '
                        'can be declared here yet.'
                  : typesAsync.isLoading
                  ? 'Loading the reliefs that may be declared…'
                  : 'No reliefs are published for tax year $taxYear yet.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: typesAsync.hasError
                    ? context.scheme.error
                    : context.scheme.onSurfaceVariant,
              ),
            ),
          ),
        AsyncView(
          value: reliefs,
          onRetry: () => ref.invalidate(declaredReliefsProvider(employeeId)),
          loading: const LinearProgressIndicator(),
          builder: (list) => list.isEmpty
              ? Text(
                  'None declared.',
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: context.scheme.onSurfaceVariant),
                )
              : Column(children: [
                  for (var i = 0; i < list.length; i++) ...[
                    if (i > 0) const Divider(height: 1),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(byCode[list[i].reliefCode]?.name ??
                          Fmt.label(list[i].reliefCode)),
                      subtitle: list[i].notes == null
                          ? null
                          : Text(list[i].notes!,
                              style: const TextStyle(fontSize: 12)),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Money(list[i].amount),
                          IconButton(
                            icon: const Icon(Icons.delete_outline, size: 18),
                            tooltip: 'Remove',
                            onPressed: () => _remove(context, ref, list[i]),
                          ),
                        ],
                      ),
                      // Same gate as Add, and for a harder reason: the
                      // dialog's dropdown is built from `types`, and
                      // Flutter asserts when a non-null value has no
                      // matching item. An empty list here is a crash,
                      // not a disabled field.
                      onTap: types.isEmpty
                          ? null
                          : () => _edit(context, ref, types, list[i]),
                    ),
                  ],
                ]),
        ),
      ],
    );
  }

  Future<void> _edit(BuildContext context, WidgetRef ref,
      List<ReliefType> types, DeclaredRelief? existing) async {
    final result = await showDialog<DeclaredRelief>(
      context: context,
      builder: (_) => _ReliefDialog(
        types: types,
        taxYear: taxYear,
        existing: existing,
      ),
    );
    if (result == null || !context.mounted) return;

    await runWithFeedback(
      context,
      action: () =>
          ref.read(repoProvider)!.saveDeclaredRelief(employeeId, result),
      successMessage: 'Relief saved',
    );
    ref.invalidate(declaredReliefsProvider(employeeId));
  }

  Future<void> _remove(
      BuildContext context, WidgetRef ref, DeclaredRelief relief) async {
    await runWithFeedback(
      context,
      action: () => ref.read(repoProvider)!.deleteDeclaredRelief(relief.id!),
      successMessage: 'Relief removed',
    );
    ref.invalidate(declaredReliefsProvider(employeeId));
  }
}

class _ReliefDialog extends StatefulWidget {
  const _ReliefDialog({
    required this.types,
    required this.taxYear,
    this.existing,
  });

  final List<ReliefType> types;
  final int taxYear;
  final DeclaredRelief? existing;

  @override
  State<_ReliefDialog> createState() => _ReliefDialogState();
}

class _ReliefDialogState extends State<_ReliefDialog> {
  // A relief already on file whose code the current schedule no longer
  // offers would give the dropdown a value with no matching item, which
  // Flutter asserts on. Falling back to the first offered code keeps the
  // dialog openable; the ceiling that then applies is the one the
  // database will judge it by either way.
  late String _code =
      widget.types.any((t) => t.code == widget.existing?.reliefCode)
      ? widget.existing!.reliefCode
      : widget.types.first.code;
  late final _amount = TextEditingController(
      text: widget.existing == null
          ? ''
          : widget.existing!.amount.toStringAsFixed(2));
  late final _notes =
      TextEditingController(text: widget.existing?.notes ?? '');
  String? _error;

  @override
  void dispose() {
    _amount.dispose();
    _notes.dispose();
    super.dispose();
  }

  ReliefType? get _type =>
      widget.types.where((t) => t.code == _code).firstOrNull;

  @override
  Widget build(BuildContext context) {
    final cap = _type?.maxAmount;

    return AlertDialog(
      title: Text(widget.existing == null ? 'Declare a relief' : 'Edit relief'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            DropdownButtonFormField<String>(
              value: _code,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Relief'),
              items: [
                for (final t in widget.types)
                  DropdownMenuItem(value: t.code, child: Text(t.name)),
              ],
              // Changing the relief changes the ceiling, so an amount
              // that was valid a moment ago may not be.
              onChanged: (v) => setState(() {
                _code = v ?? _code;
                _error = null;
              }),
            ),
            const SizedBox(height: Space.md),
            TextField(
              controller: _amount,
              autofocus: true,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(
                labelText: 'Amount',
                prefixText: 'RM ',
                errorText: _error,
                helperText: cap == null
                    ? null
                    : 'LHDN allows up to ${Fmt.money(cap)}',
              ),
            ),
            const SizedBox(height: Space.md),
            TextField(
              controller: _notes,
              decoration: const InputDecoration(
                labelText: 'Note',
                helperText: 'Receipt reference, for when it is queried',
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Save')),
      ],
    );
  }

  void _submit() {
    final amount = double.tryParse(_amount.text.trim());
    if (amount == null || amount <= 0) {
      setState(() => _error = 'Enter an amount');
      return;
    }
    // The ceiling is the law's, not a preference — over-claiming here
    // under-deducts PCB and the employee pays for it at filing.
    final cap = _type?.maxAmount;
    if (cap != null && amount > cap) {
      setState(() => _error = 'The most allowed is ${Fmt.money(cap)}');
      return;
    }
    Navigator.pop(
      context,
      DeclaredRelief(
        id: widget.existing?.id,
        reliefCode: _code,
        amount: amount,
        taxYear: widget.taxYear,
        notes: _notes.text.trim().isEmpty ? null : _notes.text.trim(),
      ),
    );
  }
}
