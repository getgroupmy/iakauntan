import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/picker_options.dart';
import '../../core/providers.dart';
import '../../core/searchable_picker.dart';
import '../../core/skeletons.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/repository.dart';

/// The rounds a candidate is put through.
///
/// `interviews` has been in the schema since talent management landed
/// and no screen has ever written one, so a candidate could be moved to
/// "interview" with no record of who saw them, when, or what they
/// thought — which is the only thing anybody wants back out of an
/// applicant tracking system three weeks later.
Future<void> showInterviews(
    BuildContext context, String applicantId, String applicantName) {
  return showDialog<void>(
    context: context,
    builder: (_) =>
        _InterviewsDialog(applicantId: applicantId, name: applicantName),
  );
}

class _InterviewsDialog extends ConsumerWidget {
  const _InterviewsDialog({required this.applicantId, required this.name});

  final String applicantId;
  final String name;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rounds = ref.watch(interviewsProvider(applicantId));

    return AlertDialog(
      title: Text('$name · interviews'),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: AsyncView(
            value: rounds,
            onRetry: () => ref.invalidate(interviewsProvider(applicantId)),
            skeleton: const ListSkeleton(rows: 3, leading: false),
            builder: (list) => Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (list.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: Space.lg),
                    child: Text('No rounds scheduled yet.'),
                  )
                else
                  for (final r in list)
                    _RoundTile(
                      round: r,
                      onEdit: () => _edit(context, ref, r, list.length),
                    ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => _edit(context, ref, null,
              (rounds.valueOrNull ?? const []).length),
          child: const Text('Add round'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Done'),
        ),
      ],
    );
  }

  Future<void> _edit(BuildContext context, WidgetRef ref,
      Map<String, dynamic>? round, int existing) async {
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => _RoundDialog(
        applicantId: applicantId,
        round: round,
        nextRound: existing + 1,
      ),
    );
    if (saved == true) ref.invalidate(interviewsProvider(applicantId));
  }
}

class _RoundTile extends StatelessWidget {
  const _RoundTile({required this.round, required this.onEdit});

  final Map<String, dynamic> round;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    final outcome = round['outcome']?.toString();
    final at = Fmt.parseDate(round['scheduled_at']);
    final interviewer = round['employees'];
    final feedback = round['feedback']?.toString();

    return ListTile(
      contentPadding: EdgeInsets.zero,
      onTap: onEdit,
      // `Wrap`, so the outcome chip drops to a second line rather
      // than off the right edge. See the header of
      // check_narrow_rows.py.
      title: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: Space.sm,
        runSpacing: 2,
        children: [
          Text('Round ${Fmt.toInt(round['round_no'])}',
              style: const TextStyle(fontWeight: FontWeight.w600)),
          if (outcome != null) StatusChip(outcome, compact: true),
        ],
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            [
              if (at != null) Fmt.dateTime(at) else 'not scheduled',
              if (round['mode'] != null) Fmt.label(round['mode'].toString()),
              if (interviewer is Map) 'with ${interviewer['full_name']}',
              if (round['score'] != null) 'scored ${round['score']}/5',
            ].whereType<Object>().join(' · '),
            style: const TextStyle(fontSize: 12),
          ),
          if (feedback != null && feedback.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(feedback,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall),
            ),
        ],
      ),
      isThreeLine: feedback != null && feedback.isNotEmpty,
    );
  }
}

class _RoundDialog extends ConsumerStatefulWidget {
  const _RoundDialog({
    required this.applicantId,
    required this.nextRound,
    this.round,
  });

  final String applicantId;
  final int nextRound;
  final Map<String, dynamic>? round;

  @override
  ConsumerState<_RoundDialog> createState() => _RoundDialogState();
}

class _RoundDialogState extends ConsumerState<_RoundDialog> {
  late final _location =
      TextEditingController(text: widget.round?['location']?.toString() ?? '');
  late final _feedback =
      TextEditingController(text: widget.round?['feedback']?.toString() ?? '');
  late final _duration = TextEditingController(
      text: (widget.round?['duration_minutes'] ?? 60).toString());

  late DateTime? _at = Fmt.parseDate(widget.round?['scheduled_at']);
  late String _mode = widget.round?['mode']?.toString() ?? 'in_person';
  late String? _outcome = widget.round?['outcome'] as String?;
  late String? _interviewer = widget.round?['interviewer_id'] as String?;
  late int _score = Fmt.toInt(widget.round?['score']);
  bool _saving = false;

  @override
  void dispose() {
    _location.dispose();
    _feedback.dispose();
    _duration.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final employees =
        ref.watch(employeesProvider('active')).valueOrNull ?? const [];

    return AlertDialog(
      title: Text(widget.round == null
          ? 'Round ${widget.nextRound}'
          : 'Round ${Fmt.toInt(widget.round!['round_no'])}'),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              InkWell(
                onTap: _pickWhen,
                child: InputDecorator(
                  decoration: const InputDecoration(
                    labelText: 'When',
                    suffixIcon: Icon(Icons.event, size: 18),
                  ),
                  child: Text(_at == null ? 'Not scheduled' : Fmt.dateTime(_at)),
                ),
              ),
              const SizedBox(height: Space.md),
              Row(children: [
                Expanded(
                  child: DropdownButtonFormField<String>(
                    initialValue: _mode,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: 'Mode'),
                    items: const [
                      DropdownMenuItem(
                          value: 'in_person', child: Text('In person')),
                      DropdownMenuItem(value: 'video', child: Text('Video')),
                      DropdownMenuItem(value: 'phone', child: Text('Phone')),
                    ],
                    onChanged: (v) => setState(() => _mode = v ?? 'in_person'),
                  ),
                ),
                const SizedBox(width: Space.md),
                SizedBox(
                  width: 110,
                  child: TextField(
                    controller: _duration,
                    keyboardType: TextInputType.number,
                    decoration:
                        const InputDecoration(labelText: 'Minutes'),
                  ),
                ),
              ]),
              const SizedBox(height: Space.md),
              TextField(
                controller: _location,
                decoration: const InputDecoration(
                  labelText: 'Where',
                  hintText: 'Meeting room 2, or a link',
                ),
              ),
              const SizedBox(height: Space.md),
              SearchablePicker<String>(
                options: employeePickerOptions(employees),
                value: _interviewer,
                label: 'Interviewer',
                hint: 'Type a name or a staff number',
                allowEmpty: true,
                emptyLabel: 'Not set',
                onChanged: (v) => setState(() => _interviewer = v),
              ),
              const Divider(height: Space.xl),
              // Everything below is filled in afterwards. A round with
              // an outcome and no feedback is the one nobody can
              // remember the reasons for.
              DropdownButtonFormField<String?>(
                initialValue: _outcome,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: 'Outcome',
                  helperText: 'Left empty until the round has happened',
                ),
                items: const [
                  DropdownMenuItem(value: null, child: Text('Not yet')),
                  DropdownMenuItem(value: 'passed', child: Text('Passed')),
                  DropdownMenuItem(value: 'failed', child: Text('Failed')),
                  DropdownMenuItem(value: 'on_hold', child: Text('On hold')),
                  DropdownMenuItem(
                      value: 'no_show', child: Text('Did not attend')),
                ],
                onChanged: (v) => setState(() => _outcome = v),
              ),
              const SizedBox(height: Space.md),
              Row(children: [
                const Text('Score'),
                const SizedBox(width: Space.md),
                Expanded(
                  child: Slider(
                    value: _score.toDouble(),
                    min: 0,
                    max: 5,
                    divisions: 5,
                    label: _score == 0 ? 'none' : '$_score',
                    onChanged: (v) => setState(() => _score = v.round()),
                  ),
                ),
                Text(_score == 0 ? '—' : '$_score / 5'),
              ]),
              const SizedBox(height: Space.sm),
              TextField(
                controller: _feedback,
                maxLines: 4,
                decoration: const InputDecoration(labelText: 'Feedback'),
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

  Future<void> _pickWhen() async {
    final day = await showDatePicker(
      context: context,
      initialDate: _at ?? DateTime.now(),
      firstDate: DateTime(DateTime.now().year - 1),
      lastDate: DateTime(DateTime.now().year + 2),
    );
    if (day == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(_at ?? DateTime.now()),
    );
    if (!mounted) return;
    setState(() => _at = DateTime(day.year, day.month, day.day,
        time?.hour ?? 9, time?.minute ?? 0));
  }

  Future<void> _save() async {
    setState(() => _saving = true);

    final values = <String, dynamic>{
      'applicant_id': widget.applicantId,
      'round_no': widget.round?['round_no'] ?? widget.nextRound,
      'scheduled_at': _at?.toIso8601String(),
      'duration_minutes': int.tryParse(_duration.text.trim()) ?? 60,
      'mode': _mode,
      'location': _location.text.trim().isEmpty ? null : _location.text.trim(),
      'interviewer_id': _interviewer,
      'outcome': _outcome,
      'score': _score == 0 ? null : _score,
      'feedback':
          _feedback.text.trim().isEmpty ? null : _feedback.text.trim(),
    };

    final ok = await runWithFeedback(
      context,
      action: () => ref
          .read(repoProvider)!
          .saveInterview(values, id: widget.round?['id'] as String?),
      successMessage: 'Saved',
    );

    if (mounted) setState(() => _saving = false);
    if (ok && mounted) Navigator.pop(context, true);
  }
}
