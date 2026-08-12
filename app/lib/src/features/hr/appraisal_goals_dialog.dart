import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/repository.dart';

/// What somebody is actually being appraised on.
///
/// `appraisal_goals` has been in the schema since talent management
/// landed and nothing could write one, so an appraisal was a pair of
/// overall ratings with nothing underneath them — a number without the
/// objectives it was a judgement about.
Future<void> showAppraisalGoals(
    BuildContext context, String appraisalId, String who) {
  return showDialog<void>(
    context: context,
    builder: (_) => _GoalsDialog(appraisalId: appraisalId, who: who),
  );
}

class _GoalsDialog extends ConsumerWidget {
  const _GoalsDialog({required this.appraisalId, required this.who});

  final String appraisalId;
  final String who;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final goals = ref.watch(appraisalGoalsProvider(appraisalId));

    return AlertDialog(
      title: Text('$who · goals'),
      content: SizedBox(
        width: 600,
        child: SingleChildScrollView(
          child: AsyncView(
            value: goals,
            onRetry: () => ref.invalidate(appraisalGoalsProvider(appraisalId)),
            builder: (list) {
              final weight = list.fold<double>(
                  0, (sum, g) => sum + Fmt.toDouble(g['weight_percent']));

              return Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (list.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: Space.lg),
                      child: Text('No goals set. The overall rating has '
                          'nothing underneath it.'),
                    )
                  else ...[
                    for (final g in list)
                      _GoalTile(
                        goal: g,
                        onEdit: () => _edit(context, ref, g, list.length),
                        onDelete: () => _delete(context, ref, g),
                      ),
                    const Divider(),
                    // Weights that do not come to a hundred make the
                    // overall rating mean whatever the reader assumes.
                    Row(children: [
                      const Expanded(child: Text('Total weight')),
                      Text(
                        '${Fmt.qty(weight)}%',
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          color: (weight - 100).abs() < 0.01
                              ? context.colors.success
                              : context.colors.warning,
                        ),
                      ),
                    ]),
                    if ((weight - 100).abs() >= 0.01)
                      Text(
                        weight < 100
                            ? 'Short of 100% — some of the rating is '
                                'unaccounted for.'
                            : 'Over 100% — the goals add up to more than the '
                                'whole job.',
                        style: TextStyle(
                            fontSize: 12, color: context.colors.warning),
                      ),
                  ],
                ],
              );
            },
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => _edit(context, ref, null,
              (goals.valueOrNull ?? const []).length),
          child: const Text('Add goal'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Done'),
        ),
      ],
    );
  }

  Future<void> _edit(BuildContext context, WidgetRef ref,
      Map<String, dynamic>? goal, int existing) async {
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => _GoalDialog(
        appraisalId: appraisalId,
        goal: goal,
        nextOrder: existing + 1,
      ),
    );
    if (saved == true) ref.invalidate(appraisalGoalsProvider(appraisalId));
  }

  Future<void> _delete(
      BuildContext context, WidgetRef ref, Map<String, dynamic> goal) async {
    await runWithFeedback(
      context,
      action: () => ref
          .read(repoProvider)!
          .deleteSetupRow('appraisal_goals', goal['id'] as String),
      successMessage: 'Removed',
    );
    ref.invalidate(appraisalGoalsProvider(appraisalId));
  }
}

class _GoalTile extends StatelessWidget {
  const _GoalTile({
    required this.goal,
    required this.onEdit,
    required this.onDelete,
  });

  final Map<String, dynamic> goal;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final self = goal['self_rating'];
    final manager = goal['manager_rating'];

    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      onTap: onEdit,
      title: Text(goal['title']?.toString() ?? ''),
      subtitle: Text(
        [
          '${Fmt.qty(Fmt.toDouble(goal['weight_percent']))}%',
          if (goal['category'] != null) goal['category'].toString(),
          if (goal['target'] != null) 'target ${goal['target']}',
          if (goal['actual'] != null) 'actual ${goal['actual']}',
        ].join(' · '),
        style: const TextStyle(fontSize: 12),
      ),
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        // Both ratings side by side, because the gap between them is
        // the conversation the appraisal exists to have.
        Text(
          '${self ?? '—'} / ${manager ?? '—'}',
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        IconButton(
          icon: const Icon(Icons.delete_outline, size: 18),
          onPressed: onDelete,
        ),
      ]),
    );
  }
}

class _GoalDialog extends ConsumerStatefulWidget {
  const _GoalDialog({
    required this.appraisalId,
    required this.nextOrder,
    this.goal,
  });

  final String appraisalId;
  final int nextOrder;
  final Map<String, dynamic>? goal;

  @override
  ConsumerState<_GoalDialog> createState() => _GoalDialogState();
}

class _GoalDialogState extends ConsumerState<_GoalDialog> {
  final _c = <String, TextEditingController>{};
  bool _saving = false;

  static const _fields = <(String, String)>[
    ('title', 'Goal *'),
    ('description', 'Detail'),
    ('category', 'Category'),
    ('weight_percent', 'Weight (%)'),
    ('target', 'Target'),
    ('actual', 'Actual'),
    ('self_rating', 'Self rating'),
    ('manager_rating', 'Manager rating'),
    ('comments', 'Comments'),
  ];

  @override
  void initState() {
    super.initState();
    for (final (key, _) in _fields) {
      _c[key] = TextEditingController(
          text: widget.goal?[key]?.toString() ??
              (key == 'weight_percent' ? '0' : ''));
    }
  }

  @override
  void dispose() {
    for (final c in _c.values) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.goal == null ? 'Add goal' : 'Edit goal'),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final (key, label) in _fields)
                Padding(
                  padding: const EdgeInsets.only(bottom: Space.md),
                  child: TextField(
                    controller: _c[key],
                    autofocus: key == 'title',
                    maxLines:
                        key == 'description' || key == 'comments' ? 2 : 1,
                    keyboardType: const {
                      'weight_percent',
                      'self_rating',
                      'manager_rating'
                    }.contains(key)
                        ? const TextInputType.numberWithOptions(decimal: true)
                        : TextInputType.text,
                    decoration: InputDecoration(labelText: label),
                  ),
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
    if (_c['title']!.text.trim().isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Name the goal')));
      return;
    }
    setState(() => _saving = true);

    double? number(String key) => double.tryParse(_c[key]!.text.trim());
    String? text(String key) =>
        _c[key]!.text.trim().isEmpty ? null : _c[key]!.text.trim();

    final ok = await runWithFeedback(
      context,
      action: () => ref.read(repoProvider)!.saveAppraisalGoal(
            {
              'appraisal_id': widget.appraisalId,
              'title': _c['title']!.text.trim(),
              'description': text('description'),
              'category': text('category'),
              'weight_percent': number('weight_percent') ?? 0,
              'target': text('target'),
              'actual': text('actual'),
              'self_rating': number('self_rating'),
              'manager_rating': number('manager_rating'),
              'comments': text('comments'),
              'sort_order': widget.goal?['sort_order'] ?? widget.nextOrder,
            },
            id: widget.goal?['id'] as String?,
          ),
      successMessage: 'Saved',
    );

    if (mounted) setState(() => _saving = false);
    if (ok && mounted) Navigator.pop(context, true);
  }
}
