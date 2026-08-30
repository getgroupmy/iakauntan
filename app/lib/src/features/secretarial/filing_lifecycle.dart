import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/corp_models.dart';
import '../../data/corp_repository.dart';
import 'person_editor.dart' show StatutoryDateField;

/// Taking a statutory deadline up, and closing it.
///
/// `corp_upcoming_filings` computes every deadline the Act imposes from
/// the entity and the statute, whether or not anybody has started work
/// on it — `filing_id` is null until `corp_open_filing` creates the
/// row. Neither `corpOpenFiling` nor `corpMarkLodged` had a caller, so
/// `corp_filings` could never leave the state the computation put it
/// in: a practice could not say it was working on an Annual Return, and
/// could not record that one had been lodged with a date and an SSM
/// reference. The screen went on showing every deadline as due or
/// overdue for as long as the entity existed.

/// Whether anybody has taken this deadline up.
bool filingIsOpen(String? filingId) => filingId != null;

/// Whether it is finished with.
///
/// `approved` is SSM having accepted it, which only follows lodgement,
/// and `not_applicable` is somebody having decided the Act does not
/// reach this company. Both are past the point where anything on this
/// screen helps.
bool filingIsSettled(String status) =>
    status == 'lodged' || status == 'approved' || status == 'not_applicable';

/// What the row offers next.
///
/// Three answers and no fourth: a deadline nobody has started, one
/// somebody is working on, and one that is over.
String filingNextStep(String? filingId, String status) {
  if (filingIsSettled(status)) return 'done';
  return filingIsOpen(filingId) ? 'lodge' : 'open';
}

/// The reference SSM gave back, or null where nothing usable was typed.
///
/// Null is what the column takes and is the honest record of a
/// lodgement whose acknowledgement has not come back yet — better than
/// a blank string that reads like a reference nobody can find.
String? ssmReferenceOf(String text) {
  final s = text.trim();
  return s.isEmpty ? null : s;
}

/// Whether a lodgement date is one that could have happened.
///
/// An affordance, not a rule: the column takes any date. A filing
/// cannot have been lodged tomorrow, and the commonest way to record
/// one wrongly is to leave the picker on a date somebody scrolled past.
bool lodgementHasHappened(DateTime on, DateTime today) => !DateTime(
      on.year,
      on.month,
      on.day,
    ).isAfter(DateTime(today.year, today.month, today.day));

/// Take a deadline up, or close it.
Future<bool> showFilingStep(
  BuildContext context, {
  required CorpFiling filing,
}) async =>
    await showDialog<bool>(
      context: context,
      builder: (_) => _StepDialog(filing: filing),
    ) ??
    false;

class _StepDialog extends ConsumerStatefulWidget {
  const _StepDialog({required this.filing});

  final CorpFiling filing;

  @override
  ConsumerState<_StepDialog> createState() => _StepDialogState();
}

class _StepDialogState extends ConsumerState<_StepDialog> {
  final _reference = TextEditingController();
  DateTime _lodgedOn = DateTime.now();
  bool _saving = false;

  String get _step =>
      filingNextStep(widget.filing.filingId, widget.filing.status);

  @override
  void dispose() {
    _reference.dispose();
    super.dispose();
  }

  Future<void> _open() async {
    setState(() => _saving = true);
    final ok = await runWithFeedback(
      context,
      action: () => ref.read(repoProvider)!.corpOpenFiling(
            widget.filing.entityId,
            widget.filing.filingType,
            widget.filing.triggerDate,
          ),
      successMessage: 'Started — it is somebody’s job now',
    );
    if (mounted) setState(() => _saving = false);
    if (ok && mounted) {
      ref.invalidate(corpFilingsProvider);
      Navigator.of(context).pop(true);
    }
  }

  Future<void> _lodge() async {
    final id = widget.filing.filingId;
    if (id == null) return;
    setState(() => _saving = true);
    final ok = await runWithFeedback(
      context,
      action: () => ref.read(repoProvider)!.corpMarkLodged(
            id,
            lodgedOn: _lodgedOn,
            reference: ssmReferenceOf(_reference.text),
          ),
      successMessage: 'Lodged',
      doing: 'Lodge a statutory filing',
    );
    if (mounted) setState(() => _saving = false);
    if (ok && mounted) {
      ref.invalidate(corpFilingsProvider);
      Navigator.of(context).pop(true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final f = widget.filing;
    final opening = _step == 'open';
    final dateOk = lodgementHasHappened(_lodgedOn, DateTime.now());

    return AlertDialog(
      title: Text(opening ? 'Start this filing' : 'Record the lodgement'),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '${f.entityName} · ${f.filingName}'
              '${f.legacyForm == null ? '' : ' (${f.legacyForm})'}',
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 2),
            Text(
              '${f.statuteRef} · due ${Fmt.date(f.dueDate)}',
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: context.scheme.onSurfaceVariant),
            ),
            const SizedBox(height: Space.md),
            if (opening)
              Text(
                'This deadline is computed from the Act and belongs to '
                'nobody yet. Starting it makes a filing somebody is '
                'working on, and the date it was triggered is what the '
                'clock runs from.',
                style: Theme.of(context).textTheme.bodySmall,
              )
            else ...[
              Row(
                children: [
                  Expanded(
                    child: StatutoryDateField(
                      label: 'Lodged on',
                      value: _lodgedOn,
                      enabled: !_saving,
                      onChanged: (d) =>
                          setState(() => _lodgedOn = d ?? _lodgedOn),
                    ),
                  ),
                  const SizedBox(width: Space.md),
                  Expanded(
                    child: TextField(
                      key: const ValueKey('ssm-reference'),
                      controller: _reference,
                      enabled: !_saving,
                      decoration: const InputDecoration(
                        labelText: 'SSM reference',
                        helperText: 'Leave it blank until it comes back',
                      ),
                    ),
                  ),
                ],
              ),
              if (!dateOk)
                Padding(
                  padding: const EdgeInsets.only(top: Space.sm),
                  child: Text(
                    'That date has not happened yet.',
                    style: Theme.of(context)
                        .textTheme
                        .bodySmall
                        ?.copyWith(color: context.colors.danger),
                  ),
                ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('filing-step'),
          onPressed: _saving || (!opening && !dateOk)
              ? null
              : (opening ? _open : _lodge),
          child: _saving
              ? const SizedBox(
                  height: 16,
                  width: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(opening ? 'Start it' : 'Lodged'),
        ),
      ],
    );
  }
}
