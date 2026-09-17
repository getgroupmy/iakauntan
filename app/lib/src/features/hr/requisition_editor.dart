import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/picker_options.dart';
import '../../core/providers.dart';
import '../../core/quick_add_dialog.dart';
import '../../core/searchable_picker.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/models.dart';
import '../../data/repository.dart';

/// Raising a vacancy at all.
///
/// `job_requisitions` had no writer: `Repo.requisitions()` selected the
/// table, the talent screen listed what it found, and nothing anywhere
/// inserted or updated a row. `hiring_manager_id`, `requirements` and
/// `target_start_date` were unwritten because no column was — the same
/// shape `0389` found on `projects`.
///
/// `0381` built the far end and could only assume this one: it hires an
/// applicant against a requisition, counts places against `headcount`,
/// and closes the requisition when the last is taken.

/// Why this requisition will not save as it stands, or null when it
/// will.
///
/// The database holds all of these too, and its refusal is the one that
/// counts. Said here so the form can answer where the typing is.
String? requisitionBlockedBecause({
  required String requisitionNo,
  required String title,
  required int headcount,
  double? salaryMin,
  double? salaryMax,
  DateTime? openedDate,
  DateTime? targetStart,
}) {
  if (requisitionNo.trim().isEmpty) return 'Give it a number.';
  if (title.trim().isEmpty) return 'Give the role a title.';
  if (headcount < 1) return 'A vacancy is for at least one person.';
  if (salaryMin != null && salaryMax != null && salaryMax < salaryMin) {
    return 'The salary band runs upwards.';
  }
  if (openedDate != null &&
      targetStart != null &&
      targetStart.isBefore(openedDate)) {
    return 'The start date cannot be before the vacancy opened.';
  }
  return null;
}

/// Whether the vacancy can be opened, or why not.
///
/// The hiring manager is the rule with teeth: applications to a
/// requisition nobody owns go into a queue nobody is reading.
String? openBlockedBecause(Map<String, dynamic> requisition) {
  final status = requisition['status']?.toString();
  if (status != 'draft' && status != 'on_hold') {
    return 'Only a draft or a vacancy on hold is opened.';
  }
  if (requisition['hiring_manager_id'] == null) {
    return 'Name the hiring manager first. Applications to a vacancy '
        'nobody owns go into a queue nobody is reading.';
  }
  return null;
}

/// The row an editor sends.
Map<String, dynamic> requisitionValues({
  required String requisitionNo,
  required String title,
  required int headcount,
  String? departmentId,
  String? hiringManagerId,
  String? location,
  double? salaryMin,
  double? salaryMax,
  String? description,
  String? requirements,
  DateTime? targetStart,
}) {
  String? clean(String? v) =>
      (v == null || v.trim().isEmpty) ? null : v.trim();

  return <String, dynamic>{
    'requisition_no': requisitionNo.trim(),
    'title': title.trim(),
    'headcount': headcount,
    'department_id': departmentId,
    'hiring_manager_id': hiringManagerId,
    'location': clean(location),
    'salary_min': salaryMin,
    'salary_max': salaryMax,
    'description': clean(description),
    'requirements': clean(requirements),
    'target_start_date':
        targetStart == null ? null : Fmt.iso(targetStart),
    // `status`, `opened_date` and `closed_date` are deliberately absent.
    // They are written by `open_requisition` and `close_requisition`,
    // because a date typed beside a status is a date that can disagree
    // with it — which is what `0387` and `0391` both found.
  };
}

Future<bool> showRequisitionEditor(
  BuildContext context, {
  Map<String, dynamic>? requisition,
}) async =>
    await showDialog<bool>(
      context: context,
      builder: (_) => _RequisitionEditor(requisition: requisition),
    ) ??
    false;

class _RequisitionEditor extends ConsumerStatefulWidget {
  const _RequisitionEditor({this.requisition});

  final Map<String, dynamic>? requisition;

  @override
  ConsumerState<_RequisitionEditor> createState() =>
      _RequisitionEditorState();
}

class _RequisitionEditorState extends ConsumerState<_RequisitionEditor> {
  late final _no = TextEditingController(
      text: widget.requisition?['requisition_no']?.toString() ?? '');
  late final _title = TextEditingController(
      text: widget.requisition?['title']?.toString() ?? '');
  late final _headcount = TextEditingController(
      text: '${widget.requisition?['headcount'] ?? 1}');
  late final _location = TextEditingController(
      text: widget.requisition?['location']?.toString() ?? '');
  late final _min = TextEditingController(
      text: widget.requisition?['salary_min']?.toString() ?? '');
  late final _max = TextEditingController(
      text: widget.requisition?['salary_max']?.toString() ?? '');
  late final _requirements = TextEditingController(
      text: widget.requisition?['requirements']?.toString() ?? '');
  late String? _deptId = widget.requisition?['department_id'] as String?;
  late String? _mgrId = widget.requisition?['hiring_manager_id'] as String?;
  late DateTime? _target =
      Fmt.parseDate(widget.requisition?['target_start_date']);
  bool _saving = false;

  @override
  void dispose() {
    for (final c in [_no, _title, _headcount, _location, _min, _max,
        _requirements]) {
      c.dispose();
    }
    super.dispose();
  }

  int get _count => int.tryParse(_headcount.text.trim()) ?? 0;
  double? _money(TextEditingController c) {
    final t = c.text.trim().replaceAll(',', '');
    return t.isEmpty ? null : double.tryParse(t);
  }

  @override
  Widget build(BuildContext context) {
    final people = ref.watch(directoryProvider).valueOrNull ??
        const <Employee>[];
    final departments =
        ref.watch(departmentsProvider).valueOrNull ?? const [];
    final blocked = requisitionBlockedBecause(
      requisitionNo: _no.text,
      title: _title.text,
      headcount: _count,
      salaryMin: _money(_min),
      salaryMax: _money(_max),
      openedDate: Fmt.parseDate(widget.requisition?['opened_date']),
      targetStart: _target,
    );

    return AlertDialog(
      title: Text(widget.requisition == null
          ? 'Raise a vacancy'
          : 'Amend the vacancy'),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(children: [
                SizedBox(
                  width: 150,
                  child: TextField(
                    key: const ValueKey('req-no'),
                    controller: _no,
                    enabled: !_saving && widget.requisition == null,
                    onChanged: (_) => setState(() {}),
                    decoration: const InputDecoration(labelText: 'Number'),
                  ),
                ),
                const SizedBox(width: Space.md),
                Expanded(
                  child: TextField(
                    key: const ValueKey('req-title'),
                    controller: _title,
                    enabled: !_saving,
                    onChanged: (_) => setState(() {}),
                    decoration: const InputDecoration(labelText: 'Role'),
                  ),
                ),
              ]),
              const SizedBox(height: Space.md),
              SearchablePicker<String>(
                key: const ValueKey('req-manager'),
                options: employeePickerOptions(people),
                value: _mgrId,
                label: 'Hiring manager',
                helperText: 'A vacancy cannot be opened without one',
                hint: 'Type a name or a staff number',
                allowEmpty: true,
                emptyLabel: 'Nobody yet',
                enabled: !_saving,
                onChanged: (v) => setState(() => _mgrId = v),
              ),
              const SizedBox(height: Space.md),
              Row(children: [
                Expanded(
                  child: SearchablePicker<String>(
                    options: [
                      for (final d in departments)
                        PickerOption<String>(
                          value: d['id'] as String,
                          label: '${d['name']}',
                        ),
                    ],
                    value: _deptId,
                    label: 'Department',
                    allowEmpty: true,
                    enabled: !_saving,
                    createLabel: 'Add department',
                    onCreate: (typed) => quickAdd(
                      context,
                      title: 'New department',
                      blurb: 'Not on the list yet. A name and a code is '
                          'all it needs; its head and its cost centre '
                          'are set in HR setup.',
                      nameHint: 'Engineering',
                      codeLabel: 'Code',
                      seed: typed,
                      save: ({required name, code}) async {
                        final id = await ref
                            .read(repoProvider)!
                            .createQuickRow(
                              QuickAddList.department,
                              name: name,
                              code: code,
                            );
                        ref.invalidate(departmentsProvider);
                        return id;
                      },
                    ),
                    onChanged: (v) => setState(() => _deptId = v),
                  ),
                ),
                const SizedBox(width: Space.md),
                SizedBox(
                  width: 120,
                  child: TextField(
                    key: const ValueKey('req-headcount'),
                    controller: _headcount,
                    enabled: !_saving,
                    keyboardType: TextInputType.number,
                    onChanged: (_) => setState(() {}),
                    decoration: const InputDecoration(labelText: 'Places'),
                  ),
                ),
              ]),
              const SizedBox(height: Space.md),
              Row(children: [
                Expanded(
                  child: TextField(
                    controller: _min,
                    enabled: !_saving,
                    keyboardType: TextInputType.number,
                    onChanged: (_) => setState(() {}),
                    decoration:
                        const InputDecoration(labelText: 'Salary from'),
                  ),
                ),
                const SizedBox(width: Space.md),
                Expanded(
                  child: TextField(
                    controller: _max,
                    enabled: !_saving,
                    keyboardType: TextInputType.number,
                    onChanged: (_) => setState(() {}),
                    decoration: const InputDecoration(labelText: 'to'),
                  ),
                ),
              ]),
              const SizedBox(height: Space.md),
              TextField(
                controller: _location,
                enabled: !_saving,
                decoration: const InputDecoration(labelText: 'Location'),
              ),
              const SizedBox(height: Space.md),
              TextField(
                key: const ValueKey('req-requirements'),
                controller: _requirements,
                enabled: !_saving,
                minLines: 2,
                maxLines: 5,
                decoration: const InputDecoration(
                  labelText: 'Requirements',
                  helperText: 'What the advertisement asks for',
                ),
              ),
              const SizedBox(height: Space.md),
              InputDecorator(
                decoration: const InputDecoration(
                  labelText: 'Wanted from',
                  helperText: 'When the role is needed to start',
                ),
                child: Row(children: [
                  Expanded(
                    child: InkWell(
                      key: const ValueKey('req-target'),
                      onTap: _saving
                          ? null
                          : () async {
                              final now = DateTime.now();
                              final picked = await showDatePicker(
                                context: context,
                                initialDate: _target ?? now,
                                firstDate: DateTime(now.year - 1),
                                lastDate: DateTime(now.year + 5),
                              );
                              if (picked != null) {
                                setState(() => _target = picked);
                              }
                            },
                      child: Padding(
                        padding:
                            const EdgeInsets.symmetric(vertical: Space.sm),
                        child:
                            Text(_target == null ? '—' : Fmt.date(_target)),
                      ),
                    ),
                  ),
                  if (_target != null && !_saving)
                    IconButton(
                      icon: const Icon(Icons.clear, size: 16),
                      onPressed: () => setState(() => _target = null),
                    ),
                ]),
              ),
              if (blocked != null) ...[
                const SizedBox(height: Space.md),
                Text(blocked,
                    style: TextStyle(
                        fontSize: 12, color: context.colors.danger)),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('req-save'),
          onPressed: _saving || blocked != null ? null : _save,
          child: _saving
              ? const SizedBox(
                  height: 16,
                  width: 16,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('Save'),
        ),
      ],
    );
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    final ok = await runWithFeedback(
      context,
      action: () => ref.read(repoProvider)!.saveRequisition(
            requisitionValues(
              requisitionNo: _no.text,
              title: _title.text,
              headcount: _count,
              departmentId: _deptId,
              hiringManagerId: _mgrId,
              location: _location.text,
              salaryMin: _money(_min),
              salaryMax: _money(_max),
              requirements: _requirements.text,
              targetStart: _target,
            ),
            id: widget.requisition?['id'] as String?,
          ),
      successMessage: 'Saved',
    );
    if (mounted) setState(() => _saving = false);
    if (ok && mounted) {
      ref.invalidate(requisitionsProvider);
      Navigator.of(context).pop(true);
    }
  }
}
