import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/repository.dart';
import '../secretarial/person_editor.dart' show StatutoryDateField;

/// The facts a set of accounts carries besides its figures.
///
/// `fs_filings` holds the auditor's name and firm number, who signed
/// the report and when, the opinion, whether going concern was
/// emphasised, the headcount the PD 3/2018 threshold test needs, and
/// the dates the directors approved and circulated them. `createFsFiling`
/// sets three of those, once, and `updateFsFiling` had no caller — so
/// every one of the rest could never be entered at all, and the
/// exemption card answered "cannot tell" forever because the headcount
/// could not be supplied after the filing was made.

const List<String> kFrameworks = ['mpers', 'mfrs'];

/// `unaudited` is not the same as `audit_exempt`. A company that
/// qualifies under PD 3/2018 and claims it files unaudited accounts on
/// that ground; one that simply has not had them audited is something
/// else, and MBRS asks which.
const List<String> kAuditStatuses = ['audited', 'audit_exempt', 'unaudited'];

const List<String> kOpinions = [
  'unmodified',
  'qualified',
  'adverse',
  'disclaimer',
];

/// What a lodged filing will no longer take.
///
/// `app.fs_refuse_lodged_edit` names exactly these: everything the
/// accounts actually say. The reference and the lodgement date stay
/// open, because a typo in what mPortal returned is a typo and not a
/// restatement. The set follows the trigger rather than the sentence
/// beside it — a field the trigger does not name is a field it allows.
const Set<String> kLodgedLockedFields = {
  'fy_start',
  'fy_end',
  'framework',
  'audit_status',
  'opinion',
  'audit_report_date',
  'auditor_name',
};

bool filingFieldIsEditable(String status, String field) =>
    status != 'lodged' || !kLodgedLockedFields.contains(field);

/// The headcount at the year end, for the threshold test.
///
/// Not derived: the `employees` table only exists for tenants on the HR
/// module, and this is a number somebody signs a declaration over.
/// Blank is a real answer and stays null — `fs_audit_exemption` says
/// "cannot tell" rather than guessing, which is the honest outcome.
int? headcountOf(String text) {
  // Blank parses to nothing, which is the same answer as a fraction or
  // a word: not a headcount. One guard covers all three.
  final v = int.tryParse(text.trim());
  if (v == null || v < 0) return null;
  return v;
}

/// Whether the financial year runs forward.
///
/// `fs_filings_period` is `fy_end > fy_start`, strictly: a year that
/// starts and ends on the same day is not a period.
bool filingPeriodRuns(DateTime? start, DateTime? end) =>
    start != null && end != null && end.isAfter(start);

String? _clean(String? text) {
  final s = text?.trim();
  return (s == null || s.isEmpty) ? null : s;
}

/// The patch, holding only what this filing will actually take.
///
/// A lodged filing is evidence. Sending it a field it refuses would
/// raise 42501 over a value the user very likely did not change, so
/// the locked fields are dropped rather than sent and argued about.
Map<String, dynamic> filingValues({
  required String status,
  required DateTime fyStart,
  required DateTime fyEnd,
  required String framework,
  required String auditStatus,
  required bool goingConcernEmphasis,
  String? opinion,
  String? auditorName,
  String? auditorFirmNo,
  String? auditorSignatory,
  DateTime? auditReportDate,
  DateTime? directorsApprovalDate,
  DateTime? circulatedOn,
  int? employeeCount,
  String? notes,
}) {
  final all = <String, dynamic>{
    'fy_start': Fmt.iso(fyStart),
    'fy_end': Fmt.iso(fyEnd),
    'framework': framework,
    'audit_status': auditStatus,
    'going_concern_emphasis': goingConcernEmphasis,
    // Null is meaningful on every one of these: an opinion not yet
    // given, an auditor not yet appointed, a headcount nobody has
    // counted. Dropping the key would leave a stale value standing.
    'opinion': _clean(opinion),
    'auditor_name': _clean(auditorName),
    'auditor_firm_no': _clean(auditorFirmNo),
    'auditor_signatory': _clean(auditorSignatory),
    'audit_report_date':
        auditReportDate == null ? null : Fmt.iso(auditReportDate),
    'directors_approval_date':
        directorsApprovalDate == null ? null : Fmt.iso(directorsApprovalDate),
    'circulated_on': circulatedOn == null ? null : Fmt.iso(circulatedOn),
    'employee_count': employeeCount,
    'notes': _clean(notes),
  };

  return <String, dynamic>{
    for (final e in all.entries)
      if (filingFieldIsEditable(status, e.key)) e.key: e.value,
  };
}

/// Enter what the accounts say.
Future<bool> showFilingDetails(
  BuildContext context, {
  required Map<String, dynamic> filing,
}) async =>
    await showDialog<bool>(
      context: context,
      builder: (_) => _DetailsDialog(filing: filing),
    ) ??
    false;

class _DetailsDialog extends ConsumerStatefulWidget {
  const _DetailsDialog({required this.filing});

  final Map<String, dynamic> filing;

  @override
  ConsumerState<_DetailsDialog> createState() => _DetailsDialogState();
}

class _DetailsDialogState extends ConsumerState<_DetailsDialog> {
  final _auditor = TextEditingController();
  final _firmNo = TextEditingController();
  final _signatory = TextEditingController();
  final _headcount = TextEditingController();
  final _notes = TextEditingController();

  late String _framework;
  late String _auditStatus;
  late bool _goingConcern;
  String? _opinion;
  DateTime? _fyStart;
  DateTime? _fyEnd;
  DateTime? _reportDate;
  DateTime? _approvalDate;
  DateTime? _circulated;
  bool _saving = false;

  String get _status => '${widget.filing['status'] ?? 'draft'}';

  @override
  void initState() {
    super.initState();
    final f = widget.filing;
    _framework = '${f['framework'] ?? 'mpers'}';
    _auditStatus = '${f['audit_status'] ?? 'audited'}';
    _goingConcern = f['going_concern_emphasis'] == true;
    _opinion = f['opinion'] as String?;
    _auditor.text = (f['auditor_name'] ?? '') as String;
    _firmNo.text = (f['auditor_firm_no'] ?? '') as String;
    _signatory.text = (f['auditor_signatory'] ?? '') as String;
    _notes.text = (f['notes'] ?? '') as String;
    final count = f['employee_count'];
    if (count != null) _headcount.text = '$count';
    _fyStart = _date(f['fy_start']);
    _fyEnd = _date(f['fy_end']);
    _reportDate = _date(f['audit_report_date']);
    _approvalDate = _date(f['directors_approval_date']);
    _circulated = _date(f['circulated_on']);
  }

  static DateTime? _date(Object? v) =>
      v == null ? null : DateTime.tryParse('$v');

  @override
  void dispose() {
    for (final c in [_auditor, _firmNo, _signatory, _headcount, _notes]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    if (!filingPeriodRuns(_fyStart, _fyEnd)) return;
    setState(() => _saving = true);

    final values = filingValues(
      status: _status,
      fyStart: _fyStart!,
      fyEnd: _fyEnd!,
      framework: _framework,
      auditStatus: _auditStatus,
      goingConcernEmphasis: _goingConcern,
      opinion: _opinion,
      auditorName: _auditor.text,
      auditorFirmNo: _firmNo.text,
      auditorSignatory: _signatory.text,
      auditReportDate: _reportDate,
      directorsApprovalDate: _approvalDate,
      circulatedOn: _circulated,
      employeeCount: headcountOf(_headcount.text),
      notes: _notes.text,
    );

    final ok = await runWithFeedback(
      context,
      action: () => ref
          .read(repoProvider)!
          .updateFsFiling('${widget.filing['id']}', values),
      successMessage: 'Saved',
    );
    if (mounted) setState(() => _saving = false);
    if (ok && mounted) Navigator.of(context).pop(true);
  }

  bool _open(String field) => filingFieldIsEditable(_status, field);

  @override
  Widget build(BuildContext context) {
    final lodged = _status == 'lodged';
    final periodRuns = filingPeriodRuns(_fyStart, _fyEnd);

    return AlertDialog(
      title: const Text('What these accounts say'),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (lodged)
                Padding(
                  padding: const EdgeInsets.only(bottom: Space.md),
                  child: Text(
                    'These have been lodged with SSM. Correcting what they '
                    'say means lodging a fresh set, so the period, the '
                    'framework, the audit status, the opinion and the '
                    'auditor are closed. The rest is still yours.',
                    style: Theme.of(context)
                        .textTheme
                        .bodySmall
                        ?.copyWith(color: context.colors.warning),
                  ),
                ),
              Row(
                children: [
                  Expanded(
                    child: StatutoryDateField(
                      label: 'Year begins',
                      value: _fyStart,
                      enabled: !_saving && _open('fy_start'),
                      onChanged: (d) => setState(() => _fyStart = d),
                    ),
                  ),
                  const SizedBox(width: Space.md),
                  Expanded(
                    child: StatutoryDateField(
                      label: 'Year ends',
                      value: _fyEnd,
                      enabled: !_saving && _open('fy_end'),
                      onChanged: (d) => setState(() => _fyEnd = d),
                    ),
                  ),
                ],
              ),
              if (!periodRuns)
                Padding(
                  padding: const EdgeInsets.only(top: Space.xs),
                  child: Text(
                    'The year has to end after it begins.',
                    style: Theme.of(context)
                        .textTheme
                        .bodySmall
                        ?.copyWith(color: context.colors.danger),
                  ),
                ),
              const SizedBox(height: Space.md),
              Row(
                children: [
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      key: const ValueKey('filing-framework'),
                      value: _framework,
                      isExpanded: true,
                      decoration:
                          const InputDecoration(labelText: 'Framework'),
                      items: [
                        for (final f in kFrameworks)
                          DropdownMenuItem(
                            value: f,
                            child: Text(f.toUpperCase()),
                          ),
                      ],
                      onChanged: _saving || !_open('framework')
                          ? null
                          : (v) => setState(() => _framework = v ?? _framework),
                    ),
                  ),
                  const SizedBox(width: Space.md),
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      key: const ValueKey('filing-audit-status'),
                      value: _auditStatus,
                      isExpanded: true,
                      decoration:
                          const InputDecoration(labelText: 'Audit status'),
                      items: [
                        for (final s in kAuditStatuses)
                          DropdownMenuItem(
                            value: s,
                            child: Text(Fmt.label(s)),
                          ),
                      ],
                      onChanged: _saving || !_open('audit_status')
                          ? null
                          : (v) =>
                              setState(() => _auditStatus = v ?? _auditStatus),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: Space.md),
              TextField(
                key: const ValueKey('filing-headcount'),
                controller: _headcount,
                enabled: !_saving,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Employees at the year end',
                  helperText: 'Leave it blank if nobody has counted. The '
                      'exemption test then says so rather than guessing.',
                ),
              ),
              const SizedBox(height: Space.lg),
              const SectionHeader('The audit report'),
              TextField(
                key: const ValueKey('filing-auditor'),
                controller: _auditor,
                enabled: !_saving && _open('auditor_name'),
                decoration: const InputDecoration(labelText: 'Audit firm'),
              ),
              const SizedBox(height: Space.md),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _firmNo,
                      enabled: !_saving,
                      decoration:
                          const InputDecoration(labelText: 'Firm number'),
                    ),
                  ),
                  const SizedBox(width: Space.md),
                  Expanded(
                    child: TextField(
                      controller: _signatory,
                      enabled: !_saving,
                      decoration: const InputDecoration(
                        labelText: 'Who signed it',
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: Space.md),
              Row(
                children: [
                  Expanded(
                    child: DropdownButtonFormField<String?>(
                      key: const ValueKey('filing-opinion'),
                      value: _opinion,
                      isExpanded: true,
                      decoration: const InputDecoration(labelText: 'Opinion'),
                      items: [
                        const DropdownMenuItem<String?>(
                          value: null,
                          child: Text('Not yet given'),
                        ),
                        for (final o in kOpinions)
                          DropdownMenuItem<String?>(
                            value: o,
                            child: Text(Fmt.label(o)),
                          ),
                      ],
                      onChanged: _saving || !_open('opinion')
                          ? null
                          : (v) => setState(() => _opinion = v),
                    ),
                  ),
                  const SizedBox(width: Space.md),
                  Expanded(
                    child: StatutoryDateField(
                      label: 'Report dated',
                      value: _reportDate,
                      enabled: !_saving && _open('audit_report_date'),
                      onChanged: (d) => setState(() => _reportDate = d),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: Space.sm),
              SwitchListTile(
                key: const ValueKey('filing-going-concern'),
                contentPadding: EdgeInsets.zero,
                title: const Text('Going concern emphasised'),
                // Asked separately from the opinion because an emphasis
                // of matter sits *with* an unmodified opinion, and MBRS
                // asks for it as its own fact.
                subtitle: Text(
                  'An emphasis of matter, which sits with an unmodified '
                  'opinion rather than modifying it.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                value: _goingConcern,
                onChanged: _saving
                    ? null
                    : (v) => setState(() => _goingConcern = v),
              ),
              const SizedBox(height: Space.lg),
              const SectionHeader('The directors'),
              Row(
                children: [
                  Expanded(
                    child: StatutoryDateField(
                      label: 'Approved on',
                      value: _approvalDate,
                      enabled: !_saving,
                      onChanged: (d) => setState(() => _approvalDate = d),
                    ),
                  ),
                  const SizedBox(width: Space.md),
                  Expanded(
                    child: StatutoryDateField(
                      label: 'Circulated on',
                      value: _circulated,
                      enabled: !_saving,
                      onChanged: (d) => setState(() => _circulated = d),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: Space.md),
              TextField(
                controller: _notes,
                enabled: !_saving,
                minLines: 2,
                maxLines: 4,
                decoration: const InputDecoration(labelText: 'Notes'),
              ),
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
          key: const ValueKey('filing-save'),
          onPressed: _saving || !periodRuns ? null : _save,
          child: _saving
              ? const SizedBox(
                  height: 16,
                  width: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Save'),
        ),
      ],
    );
  }
}
