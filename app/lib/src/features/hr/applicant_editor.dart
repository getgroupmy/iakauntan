import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/models.dart';
import '../../data/repository.dart';
import 'hiring.dart';

/// A candidate, and what the company knows about them.
///
/// The pipeline could move somebody from `applied` to `hired` and never
/// record who introduced them, what they owe their current employer, or
/// where they work now — `current_employer`, `notice_period_days` and
/// `referred_by` have been columns since `0036` and nothing wrote any of
/// them. The last of those made an employee referral scheme unpayable
/// from the data.
Future<bool> showApplicantEditor(
  BuildContext context, {
  Applicant? applicant,
  String? requisitionId,
}) async =>
    await showDialog<bool>(
      context: context,
      builder: (_) => _ApplicantEditor(
        applicant: applicant,
        requisitionId: requisitionId,
      ),
    ) ??
    false;

class _ApplicantEditor extends ConsumerStatefulWidget {
  const _ApplicantEditor({this.applicant, this.requisitionId});

  final Applicant? applicant;
  final String? requisitionId;

  @override
  ConsumerState<_ApplicantEditor> createState() => _ApplicantEditorState();
}

class _ApplicantEditorState extends ConsumerState<_ApplicantEditor> {
  final _c = <String, TextEditingController>{};
  String? _requisitionId;
  String? _referredBy;
  bool _saving = false;

  static const _fields = <(String, String)>[
    ('full_name', 'Name *'),
    ('email', 'Email'),
    ('phone', 'Phone'),
    ('nric', 'NRIC'),
    ('current_employer', 'Currently at'),
    ('current_position', 'Currently doing'),
    ('expected_salary', 'Expects (RM)'),
    ('notice_period_days', 'Notice owed (days)'),
    ('notes', 'Notes'),
  ];

  bool get _isNew => widget.applicant == null;

  @override
  void initState() {
    super.initState();
    final a = widget.applicant;
    for (final (key, _) in _fields) {
      _c[key] = TextEditingController(text: _initial(a, key));
    }
    _requisitionId = a?.requisitionId ?? widget.requisitionId;
    _referredBy = a?.referredBy;
  }

  String _initial(Applicant? a, String key) => switch (key) {
        'full_name' => a?.fullName ?? '',
        'email' => a?.email ?? '',
        'phone' => a?.phone ?? '',
        'nric' => a?.nric ?? '',
        'current_employer' => a?.currentEmployer ?? '',
        'current_position' => a?.currentPosition ?? '',
        'expected_salary' => a?.expectedSalary?.toString() ?? '',
        'notice_period_days' => a?.noticePeriodDays?.toString() ?? '',
        'notes' => a?.notes ?? '',
        _ => '',
      };

  @override
  void dispose() {
    for (final c in _c.values) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reqs = ref.watch(requisitionsProvider).valueOrNull ?? const [];
    final staff = ref.watch(directoryProvider).valueOrNull ?? const [];
    final earliest = earliestStartDate(
      noticePeriodDays: int.tryParse(_c['notice_period_days']!.text.trim()),
      today: DateTime.now(),
    );

    return AlertDialog(
      title: Text(_isNew ? 'Add a candidate' : 'Edit candidate'),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final (key, label) in _fields) ...[
                TextField(
                  controller: _c[key],
                  autofocus: key == 'full_name',
                  maxLines: key == 'notes' ? 3 : 1,
                  keyboardType: const {
                    'expected_salary',
                    'notice_period_days',
                  }.contains(key)
                      ? const TextInputType.numberWithOptions(decimal: true)
                      : TextInputType.text,
                  onChanged: key == 'notice_period_days'
                      ? (_) => setState(() {})
                      : null,
                  decoration: InputDecoration(
                    labelText: label,
                    helperText: key == 'notice_period_days' &&
                            earliest != null
                        // Not a reminder. `hire_applicant` refuses a
                        // start inside it unless somebody says why.
                        ? 'Earliest start ${Fmt.date(earliest)}'
                        : null,
                  ),
                ),
                const SizedBox(height: Space.md),
              ],
              DropdownButtonFormField<String>(
                key: const ValueKey('applicant-requisition'),
                value: _requisitionId,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'For which role'),
                items: [
                  const DropdownMenuItem(value: null, child: Text('None')),
                  for (final r in reqs)
                    DropdownMenuItem(
                      value: r.id,
                      child: Text('${r.requisitionNo} · ${r.title}',
                          overflow: TextOverflow.ellipsis),
                    ),
                ],
                onChanged:
                    _saving ? null : (v) => setState(() => _requisitionId = v),
              ),
              const SizedBox(height: Space.md),
              DropdownButtonFormField<String>(
                key: const ValueKey('applicant-referrer'),
                value: _referredBy,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: 'Referred by',
                  helperText: 'Who introduced them, which is what a '
                      'referral scheme pays on.',
                ),
                items: [
                  const DropdownMenuItem(value: null, child: Text('Nobody')),
                  for (final e in staff)
                    DropdownMenuItem(
                      value: e.id,
                      child: Text(e.fullName, overflow: TextOverflow.ellipsis),
                    ),
                ],
                onChanged:
                    _saving ? null : (v) => setState(() => _referredBy = v),
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
    if (_c['full_name']!.text.trim().isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Name the candidate')));
      return;
    }
    setState(() => _saving = true);

    String? text(String key) =>
        _c[key]!.text.trim().isEmpty ? null : _c[key]!.text.trim();

    final ok = await runWithFeedback(
      context,
      action: () => ref.read(repoProvider)!.saveApplicant(
            {
              'full_name': _c['full_name']!.text.trim(),
              'email': text('email'),
              'phone': text('phone'),
              'nric': text('nric'),
              'current_employer': text('current_employer'),
              'current_position': text('current_position'),
              'expected_salary':
                  double.tryParse(_c['expected_salary']!.text.trim()),
              'notice_period_days':
                  int.tryParse(_c['notice_period_days']!.text.trim()),
              'requisition_id': _requisitionId,
              'referred_by': _referredBy,
              // Derived rather than asked twice. Somebody who names a
              // referrer came by referral, and a source that could say
              // otherwise is a second answer to one question.
              'source': _referredBy != null ? 'referral' : null,
              'notes': text('notes'),
            },
            id: widget.applicant?.id,
          ),
      successMessage: 'Saved',
    );

    if (mounted) setState(() => _saving = false);
    if (ok && mounted) {
      ref.invalidate(applicantsProvider);
      Navigator.pop(context, true);
    }
  }
}
