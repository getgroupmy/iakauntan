import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/searchable_picker.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/repository.dart';
import 'expiring_documents.dart';

/// The three lists that hang off an employee and had nowhere to live:
/// dependants, documents and shift assignments.
///
/// Each matters for a different reason. Dependants carry the tax relief
/// claim, so PCB is wrong without them. Documents carry expiry dates —
/// a work permit that lapsed is the sort of thing nobody notices until
/// an inspector does. `employee_shifts` is what attendance measures
/// lateness and overtime against, so with none assigned every punch is
/// simply "present".
class EmployeeRecords extends ConsumerWidget {
  const EmployeeRecords({super.key, required this.employeeId});

  final String employeeId;

  ({String table, String employeeId, String select, String orderBy}) _arg(
          String table,
          {String select = '*',
          String orderBy = 'created_at'}) =>
      (
        table: table,
        employeeId: employeeId,
        select: select,
        orderBy: orderBy
      );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 24),
        _Section(
          title: 'Dependants',
          subtitle: 'Each one carries a tax relief claim, so PCB is '
              'understated without them',
          arg: _arg('employee_dependants', orderBy: 'name'),
          onAdd: () => _edit(context, ref, 'employee_dependants', null),
          tile: (row) => ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            onTap: () => _edit(context, ref, 'employee_dependants', row),
            title: Text(row['name']?.toString() ?? ''),
            subtitle: Text(
              [
                Fmt.label(row['relationship']?.toString() ?? ''),
                if (row['date_of_birth'] != null)
                  'born ${Fmt.date(Fmt.parseDate(row['date_of_birth']))}',
                if (row['is_disabled'] == true) 'disabled',
                if (row['in_higher_education'] == true) 'in higher education',
                if (row['is_tax_dependant'] == true)
                  'relief ${Fmt.qty(Fmt.toDouble(row['relief_claim_percent']))}%'
                else
                  'no relief claimed',
              ].join(' · '),
              style: const TextStyle(fontSize: 12),
            ),
            trailing: _deleteButton(
                context, ref, 'employee_dependants', row, orderBy: 'name'),
          ),
        ),
        _Section(
          title: 'Documents',
          subtitle: 'Passports, permits, certificates — and when they expire',
          arg: _arg('employee_documents', orderBy: 'expires_date'),
          onAdd: () => _edit(context, ref, 'employee_documents', null),
          tile: (row) {
            final expires = Fmt.parseDate(row['expires_date']);
            final lapsed = expires != null && expires.isBefore(DateTime.now());
            final soon = expires != null &&
                !lapsed &&
                expires.isBefore(DateTime.now().add(const Duration(days: 60)));

            return ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              onTap: () => _edit(context, ref, 'employee_documents', row),
              title: Text(row['title']?.toString() ?? ''),
              subtitle: Text(
                [
                  Fmt.label(row['doc_type']?.toString() ?? ''),
                  if (expires != null)
                    lapsed
                        ? 'expired ${Fmt.date(expires)}'
                        : 'expires ${Fmt.date(expires)}',
                ].join(' · '),
                style: TextStyle(
                  fontSize: 12,
                  color: lapsed
                      ? context.colors.danger
                      : soon
                          ? context.colors.warning
                          : null,
                  fontWeight: lapsed || soon ? FontWeight.w600 : null,
                ),
              ),
              trailing: _deleteButton(
                  context, ref, 'employee_documents', row,
                  orderBy: 'expires_date'),
            );
          },
        ),
        _Section(
          title: 'Shifts',
          subtitle: 'What attendance measures lateness and overtime against',
          arg: _arg('employee_shifts',
              select: '*, work_shifts(name, start_time, end_time)',
              orderBy: 'effective_from'),
          onAdd: () => _edit(context, ref, 'employee_shifts', null),
          tile: (row) {
            final shift = row['work_shifts'];
            final to = Fmt.parseDate(row['effective_to']);
            return ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              onTap: () => _edit(context, ref, 'employee_shifts', row),
              title: Text(shift is Map
                  ? '${shift['name']} · ${shift['start_time']}–${shift['end_time']}'
                  : 'Shift'),
              subtitle: Text(
                to == null
                    ? 'from ${Fmt.date(Fmt.parseDate(row['effective_from']))}'
                    : '${Fmt.date(Fmt.parseDate(row['effective_from']))} to '
                        '${Fmt.date(to)}',
                style: const TextStyle(fontSize: 12),
              ),
              trailing: _deleteButton(context, ref, 'employee_shifts', row,
                  select: '*, work_shifts(name, start_time, end_time)',
                  orderBy: 'effective_from'),
            );
          },
        ),
      ],
    );
  }

  Widget _deleteButton(
    BuildContext context,
    WidgetRef ref,
    String table,
    Map<String, dynamic> row, {
    String select = '*',
    String orderBy = 'created_at',
  }) =>
      IconButton(
        icon: const Icon(Icons.delete_outline, size: 18),
        onPressed: () async {
          await runWithFeedback(
            context,
            action: () => ref
                .read(repoProvider)!
                .deleteSetupRow(table, row['id'] as String),
            successMessage: 'Removed',
          );
          ref.invalidate(employeeRowsProvider(
              _arg(table, select: select, orderBy: orderBy)));
        },
      );

  Future<void> _edit(BuildContext context, WidgetRef ref, String table,
      Map<String, dynamic>? row) async {
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => switch (table) {
        'employee_dependants' =>
          _DependantDialog(employeeId: employeeId, row: row),
        'employee_documents' =>
          _DocumentDialog(employeeId: employeeId, row: row),
        _ => _ShiftDialog(employeeId: employeeId, row: row),
      },
    );
    if (saved != true) return;

    ref.invalidate(employeeRowsProvider(_arg(table,
        select: table == 'employee_shifts'
            ? '*, work_shifts(name, start_time, end_time)'
            : '*',
        orderBy: switch (table) {
          'employee_dependants' => 'name',
          'employee_documents' => 'expires_date',
          _ => 'effective_from',
        })));
  }
}

class _Section extends ConsumerWidget {
  const _Section({
    required this.title,
    required this.subtitle,
    required this.arg,
    required this.onAdd,
    required this.tile,
  });

  final String title;
  final String subtitle;
  final ({String table, String employeeId, String select, String orderBy}) arg;
  final VoidCallback onAdd;
  final Widget Function(Map<String, dynamic>) tile;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rows = ref.watch(employeeRowsProvider(arg));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(children: [
          Expanded(child: SectionHeader(title, subtitle: subtitle)),
          TextButton.icon(
            onPressed: onAdd,
            icon: const Icon(Icons.add, size: 18),
            label: const Text('Add'),
          ),
        ]),
        AsyncView(
          value: rows,
          onRetry: () => ref.invalidate(employeeRowsProvider(arg)),
          builder: (list) => list.isEmpty
              ? const Padding(
                  padding: EdgeInsets.symmetric(vertical: Space.sm),
                  child: Text('None recorded.',
                      style: TextStyle(fontSize: 12)),
                )
              : Column(children: [for (final r in list) tile(r)]),
        ),
        const SizedBox(height: 20),
      ],
    );
  }
}

class _DependantDialog extends ConsumerStatefulWidget {
  const _DependantDialog({required this.employeeId, this.row});

  final String employeeId;
  final Map<String, dynamic>? row;

  @override
  ConsumerState<_DependantDialog> createState() => _DependantDialogState();
}

class _DependantDialogState extends ConsumerState<_DependantDialog> {
  late final _name =
      TextEditingController(text: widget.row?['name']?.toString() ?? '');
  late final _nric =
      TextEditingController(text: widget.row?['nric']?.toString() ?? '');
  late final _relief = TextEditingController(
      text: (widget.row?['relief_claim_percent'] ?? 100).toString());
  late String _relationship =
      widget.row?['relationship']?.toString() ?? 'child';
  late DateTime? _dob = Fmt.parseDate(widget.row?['date_of_birth']);
  late bool _disabled = widget.row?['is_disabled'] == true;
  late bool _education = widget.row?['in_higher_education'] == true;
  late bool _taxDependant = widget.row?['is_tax_dependant'] != false;
  bool _saving = false;

  @override
  void dispose() {
    _name.dispose();
    _nric.dispose();
    _relief.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.row == null ? 'Add dependant' : 'Edit dependant'),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: _name,
                autofocus: true,
                decoration: const InputDecoration(labelText: 'Name *'),
              ),
              const SizedBox(height: Space.md),
              DropdownButtonFormField<String>(
                value: _relationship,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Relationship'),
                items: const [
                  DropdownMenuItem(value: 'spouse', child: Text('Spouse')),
                  DropdownMenuItem(value: 'child', child: Text('Child')),
                  DropdownMenuItem(value: 'parent', child: Text('Parent')),
                  DropdownMenuItem(value: 'other', child: Text('Other')),
                ],
                onChanged: (v) => setState(() => _relationship = v ?? 'child'),
              ),
              const SizedBox(height: Space.md),
              TextField(
                controller: _nric,
                decoration: const InputDecoration(labelText: 'NRIC'),
              ),
              const SizedBox(height: Space.md),
              InkWell(
                onTap: () async {
                  final picked = await showDatePicker(
                    context: context,
                    initialDate: _dob ?? DateTime(2010),
                    firstDate: DateTime(1920),
                    lastDate: DateTime.now(),
                  );
                  if (picked != null) setState(() => _dob = picked);
                },
                child: InputDecorator(
                  decoration: const InputDecoration(
                    labelText: 'Date of birth',
                    suffixIcon: Icon(Icons.calendar_today, size: 18),
                  ),
                  child: Text(_dob == null ? 'Not set' : Fmt.date(_dob)),
                ),
              ),
              const SizedBox(height: Space.sm),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: _taxDependant,
                onChanged: (v) => setState(() => _taxDependant = v),
                title: const Text('Claimed for tax relief'),
              ),
              // Two parents may each claim part of the same child, which
              // is why this is a percentage rather than a flag.
              if (_taxDependant)
                TextField(
                  controller: _relief,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(
                    labelText: 'Share of the claim',
                    suffixText: '%',
                    helperText: 'Fifty where both parents claim half',
                  ),
                ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: _disabled,
                onChanged: (v) => setState(() => _disabled = v),
                title: const Text('Disabled'),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: _education,
                onChanged: (v) => setState(() => _education = v),
                title: const Text('In higher education'),
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
          onPressed: _saving ? null : _save,
          child: _saving
              ? const SizedBox(
                  height: 18,
                  width: 18,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('Save'),
        ),
      ],
    );
  }

  Future<void> _save() async {
    if (_name.text.trim().isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Name the dependant')));
      return;
    }
    setState(() => _saving = true);

    final ok = await runWithFeedback(
      context,
      action: () => ref.read(repoProvider)!.saveEmployeeRow(
            'employee_dependants',
            {
              'employee_id': widget.employeeId,
              'name': _name.text.trim(),
              'relationship': _relationship,
              'nric': _nric.text.trim().isEmpty ? null : _nric.text.trim(),
              'date_of_birth': _dob == null ? null : Fmt.iso(_dob!),
              'is_disabled': _disabled,
              'in_higher_education': _education,
              'is_tax_dependant': _taxDependant,
              'relief_claim_percent':
                  double.tryParse(_relief.text.trim()) ?? 100,
            },
            id: widget.row?['id'] as String?,
          ),
      successMessage: 'Saved',
    );

    if (mounted) setState(() => _saving = false);
    if (ok && mounted) Navigator.pop(context, true);
  }
}

class _DocumentDialog extends ConsumerStatefulWidget {
  const _DocumentDialog({required this.employeeId, this.row});

  final String employeeId;
  final Map<String, dynamic>? row;

  @override
  ConsumerState<_DocumentDialog> createState() => _DocumentDialogState();
}

class _DocumentDialogState extends ConsumerState<_DocumentDialog> {
  late final _title =
      TextEditingController(text: widget.row?['title']?.toString() ?? '');
  late final _notes =
      TextEditingController(text: widget.row?['notes']?.toString() ?? '');
  late String _type = widget.row?['doc_type']?.toString() ?? 'other';
  late DateTime? _issued = Fmt.parseDate(widget.row?['issued_date']);
  late DateTime? _expires = Fmt.parseDate(widget.row?['expires_date']);
  bool _saving = false;

  @override
  void dispose() {
    _title.dispose();
    _notes.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.row == null ? 'Add document' : 'Edit document'),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: _title,
                autofocus: true,
                decoration: const InputDecoration(
                    labelText: 'Title *', hintText: 'Employment pass'),
              ),
              const SizedBox(height: Space.md),
              DropdownButtonFormField<String>(
                value: _type,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Kind'),
                items: const [
                  DropdownMenuItem(value: 'identity', child: Text('Identity')),
                  DropdownMenuItem(value: 'permit', child: Text('Work permit')),
                  DropdownMenuItem(
                      value: 'contract', child: Text('Contract')),
                  DropdownMenuItem(
                      value: 'certificate', child: Text('Certificate')),
                  DropdownMenuItem(value: 'other', child: Text('Other')),
                ],
                onChanged: (v) => setState(() => _type = v ?? 'other'),
              ),
              const SizedBox(height: Space.md),
              Row(children: [
                Expanded(
                  child: _DateField(
                    label: 'Issued',
                    value: _issued,
                    onChanged: (d) => setState(() => _issued = d),
                  ),
                ),
                const SizedBox(width: Space.md),
                Expanded(
                  child: _DateField(
                    label: 'Expires',
                    value: _expires,
                    onChanged: (d) => setState(() => _expires = d),
                  ),
                ),
              ]),
              const SizedBox(height: Space.md),
              TextField(
                controller: _notes,
                maxLines: 2,
                decoration: const InputDecoration(labelText: 'Notes'),
              ),
            ],
          ),
        ),
      ),
      actions: [
        // A renewal is not an edit. Typing over the expiry date loses
        // the document that was in force until now, and the register a
        // labour inspection asks for is the history, not the latest
        // row.
        if (canRenewDocument(widget.row))
          TextButton(
            key: const ValueKey('document-renew'),
            onPressed: _saving
                ? null
                : () async {
                    final done = await showRenewDocument(
                      context,
                      documentId: widget.row!['id'] as String,
                      currentExpiry:
                          Fmt.parseDate(widget.row!['expires_date']),
                    );
                    if (done && context.mounted) {
                      Navigator.pop(context, true);
                    }
                  },
            child: const Text('Renew'),
          ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: _saving
              ? const SizedBox(
                  height: 18,
                  width: 18,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('Save'),
        ),
      ],
    );
  }

  Future<void> _save() async {
    if (_title.text.trim().isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Give it a title')));
      return;
    }
    if (_issued != null && _expires != null && _expires!.isBefore(_issued!)) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('A document cannot expire before it was issued'),
      ));
      return;
    }
    setState(() => _saving = true);

    final ok = await runWithFeedback(
      context,
      action: () => ref.read(repoProvider)!.saveEmployeeRow(
            'employee_documents',
            {
              'employee_id': widget.employeeId,
              'doc_type': _type,
              'title': _title.text.trim(),
              'issued_date': _issued == null ? null : Fmt.iso(_issued!),
              'expires_date': _expires == null ? null : Fmt.iso(_expires!),
              'notes': _notes.text.trim().isEmpty ? null : _notes.text.trim(),
            },
            id: widget.row?['id'] as String?,
          ),
      successMessage: 'Saved',
    );

    if (mounted) setState(() => _saving = false);
    if (ok && mounted) Navigator.pop(context, true);
  }
}

class _ShiftDialog extends ConsumerStatefulWidget {
  const _ShiftDialog({required this.employeeId, this.row});

  final String employeeId;
  final Map<String, dynamic>? row;

  @override
  ConsumerState<_ShiftDialog> createState() => _ShiftDialogState();
}

class _ShiftDialogState extends ConsumerState<_ShiftDialog> {
  late String? _shiftId = widget.row?['shift_id'] as String?;
  late DateTime _from =
      Fmt.parseDate(widget.row?['effective_from']) ?? DateTime.now();
  late DateTime? _to = Fmt.parseDate(widget.row?['effective_to']);
  bool _saving = false;

  @override
  Widget build(BuildContext context) {
    final shifts = ref
            .watch(setupRowsProvider((table: 'work_shifts', orderBy: 'name')))
            .valueOrNull ??
        const [];
    if (_shiftId == null && shifts.isNotEmpty) {
      _shiftId = shifts.first['id'] as String;
    }

    return AlertDialog(
      title: Text(widget.row == null ? 'Assign a shift' : 'Edit assignment'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (shifts.isEmpty)
              const Text('No shifts have been set up under HR setup yet.')
            else
              SearchablePicker<String>(
                options: [
                  for (final s in shifts)
                    PickerOption<String>(
                      value: s['id'] as String,
                      label: '${s['name']}',
                      // The HOURS, because two shifts called "Morning"
                      // at two sites are told apart by nothing else.
                      sublabel: '${s['start_time']}–${s['end_time']}',
                    ),
                ],
                value: _shiftId,
                label: 'Shift',
                onChanged: (v) => setState(() => _shiftId = v),
              ),
            const SizedBox(height: Space.md),
            _DateField(
              label: 'From',
              value: _from,
              onChanged: (d) => setState(() => _from = d ?? _from),
            ),
            const SizedBox(height: Space.md),
            // An open-ended assignment is the normal case; a closing
            // date is for somebody moving off a rota.
            _DateField(
              label: 'Until',
              value: _to,
              onChanged: (d) => setState(() => _to = d),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _saving || _shiftId == null ? null : _save,
          child: _saving
              ? const SizedBox(
                  height: 18,
                  width: 18,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('Save'),
        ),
      ],
    );
  }

  Future<void> _save() async {
    if (_to != null && _to!.isBefore(_from)) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('The assignment cannot end before it starts'),
      ));
      return;
    }
    setState(() => _saving = true);

    final ok = await runWithFeedback(
      context,
      action: () => ref.read(repoProvider)!.saveEmployeeRow(
            'employee_shifts',
            {
              'employee_id': widget.employeeId,
              'shift_id': _shiftId,
              'effective_from': Fmt.iso(_from),
              'effective_to': _to == null ? null : Fmt.iso(_to!),
            },
            id: widget.row?['id'] as String?,
          ),
      successMessage: 'Saved',
    );

    if (mounted) setState(() => _saving = false);
    if (ok && mounted) Navigator.pop(context, true);
  }
}

class _DateField extends StatelessWidget {
  const _DateField({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final DateTime? value;
  final ValueChanged<DateTime?> onChanged;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () async {
        final picked = await showDatePicker(
          context: context,
          initialDate: value ?? DateTime.now(),
          firstDate: DateTime(1990),
          lastDate: DateTime(DateTime.now().year + 20),
        );
        if (picked != null) onChanged(picked);
      },
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: label,
          suffixIcon: value == null
              ? const Icon(Icons.calendar_today, size: 18)
              : IconButton(
                  icon: const Icon(Icons.clear, size: 18),
                  onPressed: () => onChanged(null),
                ),
        ),
        child: Text(value == null ? 'Not set' : Fmt.date(value)),
      ),
    );
  }
}
