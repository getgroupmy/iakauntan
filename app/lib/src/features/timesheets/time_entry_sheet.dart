import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/searchable_picker.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/models.dart';
import '../../data/repository.dart';
import '../secretarial/person_editor.dart' show StatutoryDateField;

/// Recording an hour.
///
/// `0164` widened `time_entries` off matters and onto projects for
/// exactly this reason, written into the migration itself: the table
/// "is welded to law firms... a consultant, an engineer, an architect
/// or an agency — everyone else who sells hours — cannot record a
/// minute". The widening landed; the form did not. The only way into
/// the table was the matter tab on the legal screen, so a firm without
/// the legal module had a Timesheets screen with three tabs, an empty
/// state inviting people to record hours, and nothing anywhere that
/// could write one. `saveTimeEntry`, which takes either anchor, had no
/// caller at all.

/// Minutes from what somebody types into a duration field.
///
/// People write a duration two ways and both are right: `1.5` for an
/// hour and a half, and `1:30` for the same. A trailing `h` is allowed
/// and ignored, because people type it. Whole minutes come out, since
/// `minutes` is an integer column and its check constraint refuses zero
/// or less.
int? minutesOf(String text) {
  var s = text.trim().toLowerCase().replaceAll(' ', '');
  if (s.isEmpty) return null;
  if (s.endsWith('h')) s = s.substring(0, s.length - 1);
  if (s.isEmpty) return null;

  if (s.contains(':')) {
    final parts = s.split(':');
    if (parts.length != 2) return null;
    final h = int.tryParse(parts[0]);
    final m = int.tryParse(parts[1]);
    if (h == null || m == null || h < 0) return null;
    // 1:60 is a typo for 2:00 and guessing which is worse than asking.
    if (m < 0 || m > 59) return null;
    final total = h * 60 + m;
    return total > 0 ? total : null;
  }

  final hours = double.tryParse(s);
  if (hours == null) return null;
  final total = (hours * 60).round();
  return total > 0 ? total : null;
}

/// What a duration reads as once it is recorded.
String hoursLabel(int minutes) => '${(minutes / 60).toStringAsFixed(2)}h';

/// The value behind one entry of the "Against" list.
///
/// Projects and matters are two tables and one question — what is this
/// hour for — so they share a dropdown, and the prefix says which table
/// the id came from. Sharing the control is also what enforces
/// `time_entries_one_anchor`: one selection cannot name both.
String anchorValue(String table, String id) => '$table:$id';

String? anchorProjectId(String? value) =>
    value != null && value.startsWith('project:') ? value.substring(8) : null;

String? anchorMatterId(String? value) =>
    value != null && value.startsWith('matter:') ? value.substring(7) : null;

/// Which entry of the list an existing row sits on, or null for an hour
/// recorded against nothing.
String? anchorOf({String? projectId, String? matterId}) {
  if (projectId != null) return anchorValue('project', projectId);
  if (matterId != null) return anchorValue('matter', matterId);
  return null;
}

/// Whether this hour is chargeable to somebody.
///
/// `app.time_entry_is_chargeable_to_something` refuses billable time
/// with no anchor: "there is otherwise nobody to invoice for it". The
/// form makes that state unreachable rather than letting the server
/// explain it afterwards.
bool chargeableToSomething({
  required bool isBillable,
  String? projectId,
  String? matterId,
}) =>
    !isBillable || projectId != null || matterId != null;

/// Whether a recorded hour can still be changed.
///
/// Once time is billed it is a line on an invoice somebody has been
/// sent. Editing it here would move the hours without moving the
/// invoice, so the row is shown and not offered for editing.
bool timeEntryIsEditable(bool isBilled) => !isBilled;

/// What a time entry is, given what was entered.
///
/// The rate is deliberately absent: `apply_billing_rate` resolves it
/// from the rate card before `calc_amount` multiplies by it, so
/// somebody logging two hours does not have to know what they are
/// charged out at. Sending a zero would be taken as "no rate given"
/// and filled in; sending a number would override the card.
Map<String, dynamic> timeEntryValues({
  required DateTime entryDate,
  required String description,
  required int minutes,
  required bool isBillable,
  String? projectId,
  String? matterId,
  String? activityCode,
  String? userId,
}) {
  final activity = activityCode?.trim();
  return <String, dynamic>{
    'entry_date': Fmt.iso(entryDate),
    'description': description.trim(),
    'minutes': minutes,
    'is_billable': isBillable,
    // Both keys, always, exactly one of them set. On an edit that moves
    // an hour from a project to a matter, leaving the old key out would
    // keep the old value and the row would name two anchors, which the
    // check constraint refuses.
    'project_id': projectId,
    'matter_id': matterId,
    'activity_code': (activity == null || activity.isEmpty) ? null : activity,
    if (userId != null) 'user_id': userId,
  };
}

const List<String> kActivityCodes = [
  'drafting',
  'attendance',
  'research',
  'court',
  'meeting',
  'travel',
  'admin',
];

/// Record an hour, or correct one.
Future<bool> showTimeEntrySheet(
  BuildContext context, {
  String? id,
  Map<String, dynamic>? existing,
}) async =>
    await showDialog<bool>(
      context: context,
      builder: (_) => _TimeEntrySheet(id: id, existing: existing),
    ) ??
    false;

class _TimeEntrySheet extends ConsumerStatefulWidget {
  const _TimeEntrySheet({this.id, this.existing});

  final String? id;
  final Map<String, dynamic>? existing;

  @override
  ConsumerState<_TimeEntrySheet> createState() => _TimeEntrySheetState();
}

class _TimeEntrySheetState extends ConsumerState<_TimeEntrySheet> {
  final _formKey = GlobalKey<FormState>();
  final _description = TextEditingController();
  final _duration = TextEditingController();

  String? _anchor;
  String? _activity;
  String? _userId;
  DateTime _date = DateTime.now();
  bool _billable = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    if (e != null) {
      _description.text = (e['description'] ?? '') as String;
      final minutes = (e['minutes'] as num?)?.toInt() ?? 0;
      if (minutes > 0) _duration.text = (minutes / 60).toStringAsFixed(2);
      _anchor = anchorOf(
        projectId: e['project_id'] as String?,
        matterId: e['matter_id'] as String?,
      );
      _activity = e['activity_code'] as String?;
      _billable = e['is_billable'] as bool? ?? true;
      _userId = e['user_id'] as String?;
      final on = e['entry_date'];
      if (on != null) _date = DateTime.parse('$on');
    }
    _userId ??= ref.read(currentUserProvider)?.id;
  }

  @override
  void dispose() {
    _description.dispose();
    _duration.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    final minutes = minutesOf(_duration.text);
    if (minutes == null) return;

    final projectId = anchorProjectId(_anchor);
    final matterId = anchorMatterId(_anchor);
    if (!chargeableToSomething(
      isBillable: _billable,
      projectId: projectId,
      matterId: matterId,
    )) {
      return;
    }

    setState(() => _saving = true);
    final values = timeEntryValues(
      entryDate: _date,
      description: _description.text,
      minutes: minutes,
      isBillable: _billable,
      projectId: projectId,
      matterId: matterId,
      activityCode: _activity,
      userId: _userId,
    );

    final ok = await runWithFeedback(
      context,
      action: () =>
          ref.read(repoProvider)!.saveTimeEntry(values, id: widget.id),
      successMessage: widget.id == null ? 'Recorded' : 'Changed',
    );

    if (mounted) setState(() => _saving = false);
    if (ok && mounted) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final projects = ref.watch(projectsProvider).valueOrNull ??
        const <Map<String, dynamic>>[];
    // A firm without the legal module has no matters and the provider
    // says so by failing; an empty list is the honest reading of that.
    final matters =
        ref.watch(mattersProvider((status: 'open', search: ''))).valueOrNull ??
            const <Matter>[];
    final team = ref.watch(teamProvider).valueOrNull ?? const <TeamMember>[];
    final people =
        team.where((m) => m.status == 'active' && m.userId != null).toList();

    final projectId = anchorProjectId(_anchor);
    final matterId = anchorMatterId(_anchor);
    final chargeable = chargeableToSomething(
      isBillable: _billable,
      projectId: projectId,
      matterId: matterId,
    );
    final minutes = minutesOf(_duration.text);

    return AlertDialog(
      title: Text(widget.id == null ? 'Record time' : 'Change this entry'),
      content: SizedBox(
        width: 500,
        child: SingleChildScrollView(
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextFormField(
                  key: const ValueKey('time-description'),
                  controller: _description,
                  autofocus: true,
                  enabled: !_saving,
                  decoration: const InputDecoration(
                    labelText: 'What did you do?',
                    hintText: 'Drafting the shareholders agreement',
                  ),
                  validator: (v) =>
                      (v ?? '').trim().isEmpty ? 'Required' : null,
                ),
                const SizedBox(height: Space.md),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: StatutoryDateField(
                        label: 'On',
                        value: _date,
                        enabled: !_saving,
                        onChanged: (d) => setState(() => _date = d ?? _date),
                      ),
                    ),
                    const SizedBox(width: Space.md),
                    Expanded(
                      child: TextFormField(
                        key: const ValueKey('time-duration'),
                        controller: _duration,
                        enabled: !_saving,
                        onChanged: (_) => setState(() {}),
                        decoration: InputDecoration(
                          labelText: 'How long',
                          hintText: '1.5 or 1:30',
                          helperText: minutes == null
                              ? null
                              : hoursLabel(minutes),
                        ),
                        validator: (v) =>
                            minutesOf(v ?? '') == null ? 'Hours' : null,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: Space.md),
                SearchablePicker<String>(
                  key: const ValueKey('time-anchor'),
                  // Projects and matters in one box, as they were in one
                  // dropdown: somebody recording an hour knows what they
                  // worked on, not which table it lives in.
                  options: [
                    for (final p in projects)
                      PickerOption<String>(
                        value: anchorValue('project', p['id'] as String),
                        label: '${p['name']}',
                        sublabel: '${p['code']}',
                        keywords: ['${p['code']}'],
                      ),
                    for (final m in matters)
                      PickerOption<String>(
                        value: anchorValue('matter', m.id),
                        label: m.name,
                        sublabel: m.matterNo,
                        keywords: [m.matterNo],
                      ),
                  ],
                  value: _anchor,
                  label: 'Against',
                  allowEmpty: true,
                  emptyLabel: 'Nothing — this is not chargeable',
                  enabled: !_saving,
                  onChanged: (v) => setState(() {
                    _anchor = v;
                    // An hour against nothing cannot be billed to
                    // anybody, and the trigger says so.
                    if (v == null) _billable = false;
                  }),
                ),
                if (projects.isEmpty && matters.isEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: Space.sm),
                    child: Text(
                      'There is nothing to charge time to yet. A project is '
                      'what hours are recorded against and what they are '
                      'billed to; set one up and this list fills in.',
                      style: Theme.of(context)
                          .textTheme
                          .bodySmall
                          ?.copyWith(color: context.colors.warning),
                    ),
                  ),
                const SizedBox(height: Space.md),
                DropdownButtonFormField<String?>(
                  key: const ValueKey('time-activity'),
                  value: _activity,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Activity'),
                  items: [
                    const DropdownMenuItem<String?>(
                      value: null,
                      child: Text('Not categorised'),
                    ),
                    for (final a in kActivityCodes)
                      DropdownMenuItem<String?>(
                        value: a,
                        child: Text(Fmt.label(a)),
                      ),
                  ],
                  onChanged: _saving ? null : (v) => setState(() => _activity = v),
                ),
                if (people.length > 1) ...[
                  const SizedBox(height: Space.md),
                  SearchablePicker<String>(
                    key: const ValueKey('time-person'),
                    options: [
                      for (final m in people)
                        PickerOption<String>(
                          value: '${m.userId}',
                          label: m.displayName,
                        ),
                    ],
                    value: _userId,
                    label: 'Whose time',
                    helperText: 'The rate comes from this person’s rate '
                        'card, not from yours.',
                    enabled: !_saving,
                    onChanged: (v) => setState(() => _userId = v),
                  ),
                ],
                const SizedBox(height: Space.sm),
                SwitchListTile(
                  key: const ValueKey('time-billable'),
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Chargeable'),
                  subtitle: Text(
                    _anchor == null
                        ? 'An hour against nothing has nobody to bill it to.'
                        : 'Unchargeable hours still count towards '
                            'utilisation.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  value: _billable,
                  onChanged: _saving || _anchor == null
                      ? null
                      : (v) => setState(() => _billable = v),
                ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('time-save'),
          onPressed:
              _saving || minutes == null || !chargeable ? null : _save,
          child: _saving
              ? const SizedBox(
                  height: 16,
                  width: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(widget.id == null ? 'Record' : 'Save'),
        ),
      ],
    );
  }
}
