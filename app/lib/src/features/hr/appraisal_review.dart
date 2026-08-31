import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/models.dart';
import '../../data/repository.dart';
import 'appraisal_part.dart';

/// The two halves of an appraisal, and the one thing this person can do
/// to it.
///
/// `appraisals` has carried both halves since talent management landed
/// and nothing could write either. Worse than the absence: `0038` grants
/// the person being appraised UPDATE on their own row, and a row policy
/// has no opinion about columns — so until `0379` the subject could set
/// their own manager rating, their own final rating and their own
/// promotion recommendation, through the ordinary endpoint.
///
/// This screen never writes a column directly. Every action is one of
/// the functions `0379` added, so what the buttons offer and what the
/// database allows are the same list.
Future<bool?> showAppraisalReview(
  BuildContext context,
  Appraisal appraisal,
  AppraisalPart part,
) {
  return showDialog<bool>(
    context: context,
    builder: (_) => _ReviewDialog(appraisal: appraisal, part: part),
  );
}

class _ReviewDialog extends ConsumerStatefulWidget {
  const _ReviewDialog({required this.appraisal, required this.part});

  final Appraisal appraisal;
  final AppraisalPart part;

  @override
  ConsumerState<_ReviewDialog> createState() => _ReviewDialogState();
}

class _ReviewDialogState extends ConsumerState<_ReviewDialog> {
  final _rating = TextEditingController();
  final _comments = TextEditingController();
  final _increment = TextEditingController();
  final _bonus = TextEditingController();
  final _plan = TextEditingController();
  final _note = TextEditingController();
  bool _promotion = false;
  bool _saving = false;

  Appraisal get a => widget.appraisal;

  late final AppraisalAction _action = appraisalAction(
    part: widget.part,
    selfSubmitted: a.selfSubmitted,
    managerSubmitted: a.managerSubmitted,
    completed: a.isComplete,
    selfDue: a.selfReviewDue,
    today: DateTime.now(),
  );

  @override
  void initState() {
    super.initState();
    // The half already written is the starting point, so a reopened
    // review is edited rather than retyped from nothing.
    switch (_action) {
      case AppraisalAction.writeSelf:
        _rating.text = a.selfRating?.toString() ?? '';
        _comments.text = a.selfComments ?? '';
      case AppraisalAction.writeManager:
        _rating.text = a.managerRating?.toString() ?? '';
        _comments.text = a.managerComments ?? '';
        _increment.text = a.recommendedIncrement?.toString() ?? '';
        _bonus.text = a.recommendedBonus?.toString() ?? '';
        _plan.text = a.developmentPlan ?? '';
        _promotion = a.promotionRecommended;
      case AppraisalAction.finalise:
        // Starts on the manager's number. Calibration is the act of
        // departing from it, so departing has to be deliberate.
        _rating.text =
            (a.finalRating ?? a.managerRating)?.toString() ?? '';
        _note.text = a.calibrationNote ?? '';
      case AppraisalAction.waiting:
        break;
    }
  }

  @override
  void dispose() {
    for (final c in [_rating, _comments, _increment, _bonus, _plan, _note]) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(a.employeeName ?? 'Appraisal'),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _Header(appraisal: a),
              const SizedBox(height: Space.md),
              _Half(
                title: 'Self review',
                who: a.employeeName,
                rating: a.selfRating,
                scale: a.ratingScaleMax,
                comments: a.selfComments,
                submittedAt: a.selfSubmittedAt,
                due: a.selfReviewDue,
              ),
              _Half(
                title: 'Manager review',
                who: a.reviewerName,
                rating: a.managerRating,
                scale: a.ratingScaleMax,
                comments: a.managerComments,
                submittedAt: a.managerSubmittedAt,
                due: a.managerReviewDue,
                extra: [
                  if (a.recommendedIncrement != null)
                    'Increment ${Fmt.qty(a.recommendedIncrement!)}%',
                  if (a.recommendedBonus != null)
                    'Bonus ${Fmt.money(a.recommendedBonus!)}',
                  if (a.promotionRecommended) 'Promotion recommended',
                ],
                plan: a.developmentPlan,
              ),
              if (a.finalRating != null)
                _Half(
                  title: 'Final',
                  rating: a.finalRating,
                  scale: a.ratingScaleMax,
                  comments: a.calibrationNote,
                  submittedAt: a.completedAt,
                ),
              const Divider(height: Space.xl),
              ..._form(context),
            ],
          ),
        ),
      ),
      actions: [
        if (widget.part == AppraisalPart.hr && !_saving) _reopenMenu(context),
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Close'),
        ),
        if (_action != AppraisalAction.waiting)
          FilledButton(
            onPressed: _saving ? null : _submit,
            child: _saving
                ? const SizedBox(
                    height: 18,
                    width: 18,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : Text(switch (_action) {
                    AppraisalAction.writeSelf => 'Submit my review',
                    AppraisalAction.writeManager => 'Submit',
                    AppraisalAction.finalise => 'Settle it',
                    AppraisalAction.waiting => '',
                  }),
          ),
      ],
    );
  }

  List<Widget> _form(BuildContext context) {
    if (_action == AppraisalAction.waiting) {
      return [
        Text(_waitingBecause(),
            style: TextStyle(color: context.colors.warning, fontSize: 13)),
      ];
    }

    return [
      TextField(
        controller: _rating,
        autofocus: true,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: InputDecoration(
          labelText: switch (_action) {
            AppraisalAction.finalise => 'Final rating *',
            _ => 'Rating *',
          },
          // The scale is the cycle's own. A 4 out of 5 and a 4 out of 10
          // are different judgements, and the box has to say which.
          helperText: 'Out of ${a.ratingScaleMax}',
        ),
      ),
      const SizedBox(height: Space.md),
      TextField(
        controller: _action == AppraisalAction.finalise ? _note : _comments,
        maxLines: 3,
        decoration: InputDecoration(
          labelText: switch (_action) {
            AppraisalAction.writeSelf => 'What you did, in your words *',
            AppraisalAction.writeManager => 'Your assessment *',
            _ => 'Calibration note',
          },
          helperText: switch (_action) {
            AppraisalAction.finalise =>
              'Required if you settle on a different number from the '
                  'manager. That difference is the only thing calibration '
                  'leaves behind.',
            _ => 'A rating with nothing written beside it is a number the '
                'other person has to guess the meaning of.',
          },
        ),
      ),
      if (_action == AppraisalAction.writeManager) ...[
        const SizedBox(height: Space.md),
        Row(children: [
          Expanded(
            child: TextField(
              controller: _increment,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(labelText: 'Increment (%)'),
            ),
          ),
          const SizedBox(width: Space.md),
          Expanded(
            child: TextField(
              controller: _bonus,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(labelText: 'Bonus'),
            ),
          ),
        ]),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: _promotion,
          onChanged: (v) => setState(() => _promotion = v),
          title: const Text('Recommend for promotion'),
        ),
        TextField(
          controller: _plan,
          maxLines: 2,
          decoration: const InputDecoration(
            labelText: 'Development plan',
            helperText: 'What happens next, rather than what happened.',
          ),
        ),
      ],
    ];
  }

  String _waitingBecause() {
    if (a.isComplete) {
      return 'Settled on ${Fmt.date(a.completedAt)}. This is the record of '
          'a conversation that has happened.';
    }
    return switch (widget.part) {
      AppraisalPart.subject =>
        'Submitted on ${Fmt.date(a.selfSubmittedAt)}. Ask HR to reopen it '
            'if it has to change.',
      AppraisalPart.reviewer when a.managerSubmitted =>
        'Submitted on ${Fmt.date(a.managerSubmittedAt)}. Ask HR to reopen '
            'it if it has to change.',
      AppraisalPart.reviewer =>
        'Waiting on their self review${a.selfReviewDue == null ? '' : ', '
            'due ${Fmt.date(a.selfReviewDue)}'}. Yours is the answer to '
            'theirs.',
      AppraisalPart.hr =>
        'Waiting on the manager review. A final rating over one half of a '
            'conversation is just the other half again.',
      AppraisalPart.none => 'Nothing to do with you.',
    };
  }

  Widget _reopenMenu(BuildContext context) {
    return PopupMenuButton<String>(
      tooltip: 'Reopen a half',
      onSelected: _reopen,
      itemBuilder: (_) => const [
        PopupMenuItem(value: 'self', child: Text('Reopen the self review')),
        PopupMenuItem(
            value: 'manager', child: Text('Reopen the manager review')),
        PopupMenuItem(value: 'final', child: Text('Unsettle the final rating')),
      ],
      child: const Padding(
        padding: EdgeInsets.symmetric(horizontal: Space.sm),
        child: Text('Reopen'),
      ),
    );
  }

  Future<void> _reopen(String side) async {
    final ok = await runWithFeedback(
      context,
      action: () => ref.read(repoProvider)!.reopenAppraisal(a.id, side),
      // What was written stays; only the stamp comes off, so the author
      // edits their own words rather than starting from a blank box.
      successMessage: 'Reopened. Nothing that was written has been lost.',
    );
    if (ok && mounted) Navigator.pop(context, true);
  }

  Future<void> _submit() async {
    final rating = double.tryParse(_rating.text.trim());
    if (!isRatingInScale(rating, a.ratingScaleMax)) {
      _say('Rate it out of ${a.ratingScaleMax}.');
      return;
    }
    final body = (_action == AppraisalAction.finalise ? _note : _comments)
        .text
        .trim();
    if (_action != AppraisalAction.finalise && body.isEmpty) {
      _say('Say something beside the number.');
      return;
    }
    // The one rule the database will refuse that is worth catching here,
    // because the answer is in the box in front of them.
    if (_action == AppraisalAction.finalise &&
        a.managerRating != rating &&
        body.isEmpty) {
      _say('The manager rated this ${Fmt.qty(a.managerRating ?? 0)}. Say why '
          'you are settling somewhere else.');
      return;
    }

    setState(() => _saving = true);
    final repo = ref.read(repoProvider)!;
    final ok = await runWithFeedback(
      context,
      action: () => switch (_action) {
        AppraisalAction.writeSelf =>
          repo.submitSelfAppraisal(a.id, rating: rating!, comments: body),
        AppraisalAction.writeManager => repo.submitManagerAppraisal(
            a.id,
            rating: rating!,
            comments: body,
            increment: double.tryParse(_increment.text.trim()),
            bonus: double.tryParse(_bonus.text.trim()),
            promotion: _promotion,
            developmentPlan:
                _plan.text.trim().isEmpty ? null : _plan.text.trim(),
          ),
        AppraisalAction.finalise => repo.finaliseAppraisal(
            a.id,
            finalRating: rating!,
            calibrationNote: body.isEmpty ? null : body,
          ),
        AppraisalAction.waiting => Future<void>.value(),
      },
      successMessage: 'Saved',
    );

    if (mounted) setState(() => _saving = false);
    if (ok && mounted) Navigator.pop(context, true);
  }

  void _say(String message) => ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(message)));
}

class _Header extends StatelessWidget {
  const _Header({required this.appraisal});

  final Appraisal appraisal;

  @override
  Widget build(BuildContext context) {
    return Row(children: [
      Expanded(
        child: Text(
          [
            if (appraisal.cycleName != null) appraisal.cycleName!,
            if (appraisal.reviewerName != null)
              'reviewed by ${appraisal.reviewerName}',
          ].join(' · '),
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ),
      StatusChip(appraisal.status, compact: true),
    ]);
  }
}

/// One half of the conversation, as it stands.
class _Half extends StatelessWidget {
  const _Half({
    required this.title,
    required this.scale,
    this.who,
    this.rating,
    this.comments,
    this.submittedAt,
    this.due,
    this.extra = const [],
    this.plan,
  });

  final String title;
  final int scale;
  final String? who;
  final double? rating;
  final String? comments;
  final DateTime? submittedAt;
  final DateTime? due;
  final List<String> extra;
  final String? plan;

  @override
  Widget build(BuildContext context) {
    final small = Theme.of(context).textTheme.bodySmall;
    return Padding(
      padding: const EdgeInsets.only(bottom: Space.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Expanded(
              child: Text(
                who == null ? title : '$title · $who',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
            Text(
              rating == null ? '—' : '${Fmt.qty(rating!)} / $scale',
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
          ]),
          Text(
            submittedAt != null
                ? 'Submitted ${Fmt.date(submittedAt)}'
                : due != null
                    ? 'Not written yet · due ${Fmt.date(due)}'
                    : 'Not written yet',
            style: small,
          ),
          if (comments != null && comments!.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: Space.xs),
              child: Text(comments!),
            ),
          if (extra.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: Space.xs),
              child: Text(extra.join(' · '), style: small),
            ),
          if (plan != null && plan!.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: Space.xs),
              child: Text('Plan: $plan', style: small),
            ),
        ],
      ),
    );
  }
}
