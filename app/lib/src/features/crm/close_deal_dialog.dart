import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/models.dart';
import 'deal_outcome.dart';

/// The question the board never asked.
///
/// Opened when a card is dropped on a closed column, so the reason is
/// captured at the moment it is known. A week later nobody remembers and
/// the salesperson has moved on, which is why this is a dialog in the
/// way rather than a field somebody might come back to.
Future<bool> showCloseDealDialog(
  BuildContext context, {
  required Opportunity deal,
  required String stageType,
}) async =>
    await showDialog<bool>(
      context: context,
      builder: (_) => _CloseDealDialog(deal: deal, stageType: stageType),
    ) ??
    false;

class _CloseDealDialog extends ConsumerStatefulWidget {
  const _CloseDealDialog({required this.deal, required this.stageType});

  final Opportunity deal;

  /// Which column it was dropped on. Won columns close as won; a lost
  /// column offers both lost and abandoned, because the board has one
  /// place to put them and they are not the same thing.
  final String stageType;

  @override
  ConsumerState<_CloseDealDialog> createState() => _CloseDealDialogState();
}

class _CloseDealDialogState extends ConsumerState<_CloseDealDialog> {
  final _reason = TextEditingController();
  final _competitor = TextEditingController();

  late String _outcome = widget.stageType == 'won' ? 'won' : 'lost';

  @override
  void dispose() {
    _reason.dispose();
    _competitor.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final why = outcomeBlockedBecause(
      outcome: _outcome,
      reason: _reason.text,
      status: widget.deal.status,
    );
    // Only the two that share the lost column. Offering "Won" here would
    // let a card dropped on Closed Lost be recorded as a win, which is
    // the board saying one thing and the record another.
    final choices = widget.stageType == 'won'
        ? const {'won': 'Won'}
        : const {'lost': 'Lost', 'abandoned': 'Abandoned'};

    return AlertDialog(
      title: Text('${widget.deal.opportunityNo} · ${widget.deal.name}'),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (choices.length > 1) ...[
                SegmentedButton<String>(
                  segments: [
                    for (final c in choices.entries)
                      ButtonSegment(value: c.key, label: Text(c.value)),
                  ],
                  selected: {_outcome},
                  onSelectionChanged: (s) =>
                      setState(() => _outcome = s.first),
                ),
                const SizedBox(height: Space.xs),
                Text(
                  _outcome == 'abandoned'
                      ? 'It went quiet, or you walked away. Counting these '
                          'as losses reports a loss rate that is not true.'
                      : 'They bought from somebody else, or decided not to.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: Space.md),
              ],
              Wrap(
                spacing: Space.xs,
                children: [
                  for (final r in reasonsFor(_outcome))
                    ChoiceChip(
                      label: Text(r),
                      selected: _reason.text == r,
                      onSelected: (_) => setState(() => _reason.text = r),
                    ),
                ],
              ),
              const SizedBox(height: Space.md),
              TextField(
                controller: _reason,
                decoration: InputDecoration(
                  labelText: outcomeNeedsReason(_outcome)
                      ? 'Why *'
                      : 'Why (optional)',
                ),
                maxLines: 2,
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: Space.md),
              TextField(
                controller: _competitor,
                decoration: const InputDecoration(
                  labelText: 'Competitor',
                  // Asked on a win as well. A win-loss report that only
                  // knows about the losses is a report about the losses.
                  helperText: 'Who else was in it, on a win or a loss',
                ),
              ),
              if (why != null)
                Padding(
                  padding: const EdgeInsets.only(top: Space.md),
                  child: Text(
                    why,
                    style:
                        TextStyle(color: Theme.of(context).colorScheme.error),
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: why != null ? null : _close,
          child: Text(closeButtonLabel(_outcome)),
        ),
      ],
    );
  }

  Future<void> _close() async {
    final ok = await runWithFeedback(
      context,
      action: () => ref.read(repoProvider)!.closeOpportunity(
            id: widget.deal.id,
            outcome: _outcome,
            reason: _reason.text.trim().isEmpty ? null : _reason.text.trim(),
            competitor: _competitor.text.trim().isEmpty
                ? null
                : _competitor.text.trim(),
          ),
      successMessage: closeButtonLabel(_outcome),
    );
    if (ok && mounted) Navigator.of(context).pop(true);
  }
}
