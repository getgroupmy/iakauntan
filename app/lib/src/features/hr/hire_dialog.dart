import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/models.dart';
import '../../data/repository.dart';
import 'hiring.dart';

/// Making the employee out of the candidate.
///
/// The form asks only for what the applicant record does not already
/// know — a number, a start date, a salary — and `hire_applicant`
/// carries the rest across. That is the point of the whole exercise:
/// `hired_employee_id` said in its own comment that it was set when
/// this happened, nothing set it, and somebody retyped the name, the
/// phone number and the NRIC from the record in front of them.
Future<bool> showHireDialog(BuildContext context, Applicant applicant) async =>
    await showDialog<bool>(
      context: context,
      builder: (_) => _HireDialog(applicant: applicant),
    ) ??
    false;

class _HireDialog extends ConsumerStatefulWidget {
  const _HireDialog({required this.applicant});

  final Applicant applicant;

  @override
  ConsumerState<_HireDialog> createState() => _HireDialogState();
}

class _HireDialogState extends ConsumerState<_HireDialog> {
  final _employeeNo = TextEditingController();
  final _salary = TextEditingController();
  final _note = TextEditingController();
  DateTime? _hireDate;
  DateTime? _dateOfBirth;
  String? _departmentId;
  String? _positionId;
  String? _managerId;
  bool _saving = false;

  Applicant get a => widget.applicant;
  DateTime get _today => DateTime.now();

  @override
  void initState() {
    super.initState();
    // The salary they asked for, as the starting point rather than the
    // answer: it is the number the conversation was about.
    _salary.text = a.expectedSalary?.toString() ?? '';
    // The earliest day they could actually start, where they owe
    // notice. Defaulting to today would propose a date the candidate
    // has already told us they cannot make.
    _hireDate = earliestStartDate(
          noticePeriodDays: a.noticePeriodDays,
          today: _today,
        ) ??
        _today;
  }

  @override
  void dispose() {
    _employeeNo.dispose();
    _salary.dispose();
    _note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final departments = ref.watch(departmentsProvider).valueOrNull ?? const [];
    final positions = ref.watch(positionsProvider).valueOrNull ?? const [];
    final staff = ref.watch(directoryProvider).valueOrNull ?? const [];
    final needsNote = startNeedsExplaining(
      hireDate: _hireDate,
      noticePeriodDays: a.noticePeriodDays,
      today: _today,
    );

    return AlertDialog(
      title: Text('Hire ${a.fullName}'),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // What comes across untouched, said out loud, so nobody
              // opens the employee editor afterwards to type it again.
              Text(
                [
                  if (a.email != null) a.email!,
                  if (a.phone != null) a.phone!,
                  if (a.nric != null) a.nric!,
                ].join(' · '),
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: Space.md),
              TextField(
                controller: _employeeNo,
                autofocus: true,
                decoration: const InputDecoration(labelText: 'Employee no *'),
              ),
              const SizedBox(height: Space.md),
              TextField(
                controller: _salary,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(
                  labelText: 'Basic salary *',
                  helperText: a.expectedSalary == null
                      ? null
                      : 'They asked for ${Fmt.money(a.expectedSalary!)}',
                ),
              ),
              const SizedBox(height: Space.md),
              OutlinedButton(
                onPressed: _saving ? null : _pickHireDate,
                child: Text('Starts: ${Fmt.date(_hireDate)}'),
              ),
              if (a.noticePeriodDays != null && a.noticePeriodDays! > 0)
                Padding(
                  padding: const EdgeInsets.only(top: Space.xs),
                  child: Text(
                    'They owe ${a.noticePeriodDays} days\' notice'
                    '${a.currentEmployer == null ? '' : ' to '
                        '${a.currentEmployer}'}, so the earliest is '
                    '${Fmt.date(earliestStartDate(
                      noticePeriodDays: a.noticePeriodDays,
                      today: _today,
                    ))}.',
                    style: TextStyle(
                      fontSize: 12,
                      color: needsNote ? context.colors.warning : null,
                    ),
                  ),
                ),
              if (needsNote) ...[
                const SizedBox(height: Space.sm),
                TextField(
                  controller: _note,
                  maxLines: 2,
                  decoration: const InputDecoration(
                    labelText: 'Why the date stands *',
                    helperText: 'Waived, bought out, agreed with their '
                        'employer. Kept with the hire.',
                  ),
                ),
              ],
              const SizedBox(height: Space.md),
              OutlinedButton(
                onPressed: _saving ? null : _pickDateOfBirth,
                child: Text('Date of birth: ${Fmt.date(_dateOfBirth)}'),
              ),
              const SizedBox(height: Space.md),
              _Pick(
                label: 'Department',
                value: _departmentId,
                options: [
                  for (final d in departments)
                    (d['id'] as String, d['name']?.toString() ?? ''),
                ],
                enabled: !_saving,
                onChanged: (v) => setState(() => _departmentId = v),
              ),
              const SizedBox(height: Space.md),
              _Pick(
                label: 'Position',
                value: _positionId,
                options: [
                  for (final p in positions)
                    (p['id'] as String, p['title']?.toString() ?? ''),
                ],
                enabled: !_saving,
                onChanged: (v) => setState(() => _positionId = v),
              ),
              const SizedBox(height: Space.md),
              _Pick(
                label: 'Reports to',
                value: _managerId,
                options: [
                  for (final e in staff) (e.id, e.fullName),
                ],
                enabled: !_saving,
                onChanged: (v) => setState(() => _managerId = v),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _saving ? null : _hire,
          child: _saving
              ? const SizedBox(
                  height: 18,
                  width: 18,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('Hire'),
        ),
      ],
    );
  }

  Future<void> _pickHireDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _hireDate ?? _today,
      firstDate: DateTime(_today.year - 1),
      lastDate: DateTime(_today.year + 2),
    );
    if (picked != null) setState(() => _hireDate = picked);
  }

  Future<void> _pickDateOfBirth() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _dateOfBirth ?? DateTime(_today.year - 30),
      firstDate: DateTime(_today.year - 80),
      lastDate: DateTime(_today.year - 15),
    );
    if (picked != null) setState(() => _dateOfBirth = picked);
  }

  Future<void> _hire() async {
    final salary = double.tryParse(_salary.text.trim());
    final why = hireBlockedBecause(
      employeeNo: _employeeNo.text,
      hireDate: _hireDate,
      basicSalary: salary,
      noticePeriodDays: a.noticePeriodDays,
      earlyStartNote: _note.text,
      today: _today,
    );
    if (why != null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(why)));
      return;
    }

    setState(() => _saving = true);
    final ok = await runWithFeedback(
      context,
      action: () => ref.read(repoProvider)!.hireApplicant(
            a.id,
            employeeNo: _employeeNo.text.trim(),
            hireDate: _hireDate!,
            basicSalary: salary!,
            dateOfBirth: _dateOfBirth,
            departmentId: _departmentId,
            positionId: _positionId,
            managerId: _managerId,
            earlyStartNote:
                _note.text.trim().isEmpty ? null : _note.text.trim(),
          ),
      successMessage: '${a.fullName} is on the payroll.',
    );

    if (mounted) setState(() => _saving = false);
    if (ok && mounted) {
      ref.invalidate(applicantsProvider);
      ref.invalidate(requisitionsProvider);
      ref.invalidate(directoryProvider);
      Navigator.pop(context, true);
    }
  }
}

class _Pick extends StatelessWidget {
  const _Pick({
    required this.label,
    required this.value,
    required this.options,
    required this.enabled,
    required this.onChanged,
  });

  final String label;
  final String? value;
  final List<(String, String)> options;
  final bool enabled;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context) {
    return DropdownButtonFormField<String>(
      value: value,
      isExpanded: true,
      decoration: InputDecoration(labelText: label),
      items: [
        const DropdownMenuItem(value: null, child: Text('—')),
        for (final (id, name) in options)
          DropdownMenuItem(
              value: id, child: Text(name, overflow: TextOverflow.ellipsis)),
      ],
      onChanged: enabled ? onChanged : null,
    );
  }
}
