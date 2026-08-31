import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/models.dart';
import '../../data/repository.dart';

/// Rounds of appraisals: the period reviewed, the scale it is scored out
/// of, and the two days the halves are due.
///
/// `appraisal_cycles` has existed since talent management landed and
/// nothing could make one, which is why nothing could make an appraisal
/// either — the empty state said "Start a cycle" and there was no way to.
/// `rating_scale_max`, `self_review_due` and `manager_review_due` were
/// columns nothing had ever read; `0379` made all three mean something,
/// so this is where they are set.
Future<void> showAppraisalCycles(BuildContext context) {
  return showDialog<void>(
    context: context,
    builder: (_) => const _CyclesDialog(),
  );
}

class _CyclesDialog extends ConsumerWidget {
  const _CyclesDialog();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cycles = ref.watch(appraisalCyclesProvider);

    return AlertDialog(
      title: const Text('Appraisal cycles'),
      content: SizedBox(
        width: 620,
        child: SingleChildScrollView(
          child: AsyncView(
            value: cycles,
            onRetry: () => ref.invalidate(appraisalCyclesProvider),
            builder: (list) => list.isEmpty
                ? const Padding(
                    padding: EdgeInsets.symmetric(vertical: Space.lg),
                    child: Text('No cycles yet. A cycle is a period, a '
                        'scale and two deadlines; opening it gives '
                        'everybody an appraisal to write.'),
                  )
                : Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (final c in list)
                        _CycleTile(
                          cycle: c,
                          onEdit: () => _edit(context, ref, c),
                          onOpen: () => _open(context, ref, c),
                        ),
                    ],
                  ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => _edit(context, ref, null),
          child: const Text('New cycle'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Done'),
        ),
      ],
    );
  }

  Future<void> _edit(
      BuildContext context, WidgetRef ref, AppraisalCycle? cycle) async {
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => _CycleDialog(cycle: cycle),
    );
    if (saved == true) ref.invalidate(appraisalCyclesProvider);
  }

  Future<void> _open(
      BuildContext context, WidgetRef ref, AppraisalCycle cycle) async {
    // Says what it will do before it does it, because it touches
    // everybody: an appraisal appears in every employee's list.
    final go = await confirm(
      context,
      title: 'Open ${cycle.name}?',
      message: 'Everybody employed at ${Fmt.date(cycle.periodEnd)} gets an '
          'appraisal to write, with their manager named as reviewer. '
          'Running it again later picks up anybody who has joined since '
          'and opens nobody twice.',
      confirmLabel: 'Open it',
    );
    if (!go || !context.mounted) return;

    var opened = 0;
    final ok = await runWithFeedback(
      context,
      action: () async {
        opened = await ref.read(repoProvider)!.openAppraisalCycle(cycle.id);
      },
      successMessage: null,
    );
    if (!ok || !context.mounted) return;

    ref.invalidate(appraisalCyclesProvider);
    ref.invalidate(appraisalsProvider);
    ref.invalidate(myAppraisalPartsProvider);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(opened == 0
          ? 'Everybody already has one.'
          : '$opened appraisal${opened == 1 ? '' : 's'} opened.'),
    ));
  }
}

class _CycleTile extends StatelessWidget {
  const _CycleTile({
    required this.cycle,
    required this.onEdit,
    required this.onOpen,
  });

  final AppraisalCycle cycle;
  final VoidCallback onEdit;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      onTap: onEdit,
      title: Row(children: [
        Flexible(
          child: Text(cycle.name,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w600)),
        ),
        const SizedBox(width: Space.sm),
        StatusChip(cycle.status, compact: true),
      ]),
      subtitle: Text(
        [
          '${Fmt.date(cycle.periodStart)} – ${Fmt.date(cycle.periodEnd)}',
          'out of ${cycle.ratingScaleMax}',
          if (cycle.selfReviewDue != null)
            'self by ${Fmt.date(cycle.selfReviewDue)}',
          if (cycle.managerReviewDue != null)
            'manager by ${Fmt.date(cycle.managerReviewDue)}',
          '${cycle.opened} open',
        ].join(' · '),
        style: const TextStyle(fontSize: 12),
      ),
      trailing: TextButton(
        onPressed: cycle.status == 'completed' ? null : onOpen,
        child: const Text('Open'),
      ),
    );
  }
}

class _CycleDialog extends ConsumerStatefulWidget {
  const _CycleDialog({this.cycle});

  final AppraisalCycle? cycle;

  @override
  ConsumerState<_CycleDialog> createState() => _CycleDialogState();
}

class _CycleDialogState extends ConsumerState<_CycleDialog> {
  final _name = TextEditingController();
  final _scale = TextEditingController(text: '5');
  DateTime? _from;
  DateTime? _to;
  DateTime? _selfDue;
  DateTime? _managerDue;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final c = widget.cycle;
    if (c != null) {
      _name.text = c.name;
      _scale.text = c.ratingScaleMax.toString();
      _from = c.periodStart;
      _to = c.periodEnd;
      _selfDue = c.selfReviewDue;
      _managerDue = c.managerReviewDue;
    } else {
      final now = DateTime.now();
      _from = DateTime(now.year, 1, 1);
      _to = DateTime(now.year, 12, 31);
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _scale.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.cycle == null ? 'New cycle' : 'Edit cycle'),
      content: SizedBox(
        width: 460,
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
              TextField(
                controller: _scale,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Rated out of *',
                  helperText: 'Every rating in this cycle is bounded by it, '
                      'so a 4 means the same thing to whoever reads it next '
                      'year.',
                ),
              ),
              _DateRow(
                label: 'Period reviewed',
                first: _from,
                second: _to,
                onFirst: (d) => setState(() => _from = d),
                onSecond: (d) => setState(() => _to = d),
              ),
              _DateRow(
                label: 'Reviews due',
                firstLabel: 'Self',
                secondLabel: 'Manager',
                first: _selfDue,
                second: _managerDue,
                onFirst: (d) => setState(() => _selfDue = d),
                onSecond: (d) => setState(() => _managerDue = d),
              ),
              const SizedBox(height: Space.sm),
              // Not a reminder. It is what releases the manager to write
              // their half when the employee never wrote theirs.
              Text(
                'The self review date is what the manager waits on. After '
                'it passes they may write theirs regardless, and the '
                'appraisal records that no self review was given.',
                style: Theme.of(context).textTheme.bodySmall,
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
    final scale = int.tryParse(_scale.text.trim()) ?? 0;
    if (_name.text.trim().isEmpty) {
      _say('Name the cycle');
      return;
    }
    if (scale < 1) {
      _say('A scale of nought is not a scale.');
      return;
    }
    if (_from == null || _to == null || _to!.isBefore(_from!)) {
      _say('A cycle ends after it starts.');
      return;
    }
    setState(() => _saving = true);

    final ok = await runWithFeedback(
      context,
      action: () => ref.read(repoProvider)!.saveAppraisalCycle(
            {
              'name': _name.text.trim(),
              'period_start': Fmt.iso(_from!),
              'period_end': Fmt.iso(_to!),
              'rating_scale_max': scale,
              'self_review_due':
                  _selfDue == null ? null : Fmt.iso(_selfDue!),
              'manager_review_due':
                  _managerDue == null ? null : Fmt.iso(_managerDue!),
            },
            id: widget.cycle?.id,
          ),
      successMessage: 'Saved',
    );

    if (mounted) setState(() => _saving = false);
    if (ok && mounted) Navigator.pop(context, true);
  }

  void _say(String message) => ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(message)));
}

class _DateRow extends StatelessWidget {
  const _DateRow({
    required this.label,
    required this.first,
    required this.second,
    required this.onFirst,
    required this.onSecond,
    this.firstLabel = 'From',
    this.secondLabel = 'To',
  });

  final String label;
  final String firstLabel;
  final String secondLabel;
  final DateTime? first;
  final DateTime? second;
  final ValueChanged<DateTime?> onFirst;
  final ValueChanged<DateTime?> onSecond;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: Space.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: Theme.of(context).textTheme.bodySmall),
          Row(children: [
            Expanded(
              child: _DateButton(
                  label: firstLabel, value: first, onPicked: onFirst),
            ),
            const SizedBox(width: Space.sm),
            Expanded(
              child: _DateButton(
                  label: secondLabel, value: second, onPicked: onSecond),
            ),
          ]),
        ],
      ),
    );
  }
}

class _DateButton extends StatelessWidget {
  const _DateButton({
    required this.label,
    required this.value,
    required this.onPicked,
  });

  final String label;
  final DateTime? value;
  final ValueChanged<DateTime?> onPicked;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton(
      onPressed: () async {
        final picked = await showDatePicker(
          context: context,
          initialDate: value ?? DateTime.now(),
          firstDate: DateTime(DateTime.now().year - 5),
          lastDate: DateTime(DateTime.now().year + 5),
        );
        if (picked != null) onPicked(picked);
      },
      child: Text('$label: ${Fmt.date(value)}'),
    );
  }
}
