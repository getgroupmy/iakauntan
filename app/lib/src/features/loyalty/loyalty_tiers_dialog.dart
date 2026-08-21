import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/repository.dart';

/// The names a scheme gives its members.
///
/// 0212 made points a ledger; this is the half customers actually talk
/// about. A balance is a number that goes up and down — a tier is a
/// name somebody keeps.
///
/// ## Bands over what was earned, not over the balance
///
/// Said on the screen as well as enforced in 0253, because it is the
/// thing a shopkeeper will assume wrongly: spending points does not
/// cost anybody their tier. A scheme where it did would punish the
/// behaviour it exists to encourage.
///
/// ## The member count is the point of the list
///
/// "Gold: 412 members" out of five hundred means Gold is a
/// participation prize. The count is what tells a shop whether its
/// thresholds mean anything, so it is on every row rather than behind
/// a report.
Future<void> showLoyaltyTiers(BuildContext context) {
  return showDialog<void>(
    context: context,
    builder: (_) => const _TiersDialog(),
  );
}

class _TiersDialog extends ConsumerWidget {
  const _TiersDialog();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tiers = ref.watch(loyaltyTiersProvider);
    final program = ref.watch(loyaltyProgramProvider).valueOrNull;

    return AlertDialog(
      title: const Text('Tiers'),
      content: SizedBox(
        width: 620,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'A member is in the highest band their earned points reach. '
                'Spending points never costs anybody a tier.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: Space.md),
              if (program != null) _Window(program: program),
              AsyncView(
                value: tiers,
                onRetry: () => ref.invalidate(loyaltyTiersProvider),
                builder: (list) {
                  if (list.isEmpty) {
                    return const Padding(
                      padding: EdgeInsets.symmetric(vertical: Space.lg),
                      child: Text(
                        'No tiers yet. "Ahli" at nought, "Perak" at 500 '
                        'and "Emas" at 2,000 is a scheme.',
                      ),
                    );
                  }
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [for (final t in list) _TierRow(tier: t)],
                  );
                },
              ),
            ],
          ),
        ),
      ),
      actions: [
        if (program != null)
          TextButton(
            onPressed: () => _edit(context, ref, '${program['id']}', null),
            child: const Text('Add tier'),
          ),
        FilledButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Done'),
        ),
      ],
    );
  }
}

Future<void> _edit(
  BuildContext context,
  WidgetRef ref,
  String programId,
  Map<String, dynamic>? tier,
) async {
  final saved = await showDialog<bool>(
    context: context,
    builder: (_) => _TierDialog(programId: programId, tier: tier),
  );
  if (saved == true) ref.invalidate(loyaltyTiersProvider);
}

/// How far back the bands look.
///
/// Its own control rather than a field on every tier, because it is a
/// property of the scheme: two tiers measuring different windows would
/// mean a member could be in both and in neither.
class _Window extends ConsumerWidget {
  const _Window({required this.program});

  final Map<String, dynamic> program;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final months = (program['tier_window_months'] as num?)?.toInt();

    return Padding(
      padding: const EdgeInsets.only(bottom: Space.md),
      child: Row(
        children: [
          const Text('Counting what was earned in the last'),
          const SizedBox(width: Space.sm),
          DropdownButton<int?>(
            value: months,
            items: const [
              DropdownMenuItem(value: null, child: Text('for ever')),
              DropdownMenuItem(value: 6, child: Text('6 months')),
              DropdownMenuItem(value: 12, child: Text('12 months')),
              DropdownMenuItem(value: 24, child: Text('24 months')),
            ],
            onChanged: (v) async {
              final repo = ref.read(repoProvider);
              if (repo == null) return;
              final ok = await runWithFeedback(
                context,
                successMessage: 'Saved',
                action: () =>
                    repo.setLoyaltyTierWindow('${program['id']}', v),
              );
              if (ok) {
                ref
                  ..invalidate(loyaltyProgramProvider)
                  ..invalidate(loyaltyTiersProvider);
              }
            },
          ),
        ],
      ),
    );
  }
}

class _TierRow extends ConsumerWidget {
  const _TierRow({required this.tier});

  final Map<String, dynamic> tier;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final live = tier['is_active'] == true;
    final members = (tier['members'] as num?)?.toInt() ?? 0;
    final mult = Fmt.toDouble(tier['multiplier']);

    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      onTap: () => _edit(context, ref, '${tier['program_id']}', tier),
      title: Text(
        '${tier['name']}',
        style: TextStyle(
          fontWeight: FontWeight.w500,
          color: live ? null : Theme.of(context).disabledColor,
        ),
      ),
      subtitle: Text(
        [
          if (!live) 'retired',
          'from ${(tier['min_points'] as num?)?.toInt() ?? 0} points',
          if (mult != 1) 'earns $mult×',
          // The number that says whether the threshold means anything.
          '$members member${members == 1 ? '' : 's'}',
        ].join(' · '),
        style: const TextStyle(fontSize: 12),
      ),
      trailing: live
          ? IconButton(
              tooltip: 'Retire',
              icon: const Icon(Icons.block_outlined, size: 18),
              onPressed: () async {
                final repo = ref.read(repoProvider);
                if (repo == null) return;
                final ok = await runWithFeedback(
                  context,
                  successMessage: 'Retired',
                  action: () => repo.retireLoyaltyTier(tier['id'] as String),
                );
                if (ok) ref.invalidate(loyaltyTiersProvider);
              },
            )
          : null,
    );
  }
}

class _TierDialog extends ConsumerStatefulWidget {
  const _TierDialog({required this.programId, this.tier});

  final String programId;
  final Map<String, dynamic>? tier;

  @override
  ConsumerState<_TierDialog> createState() => _TierDialogState();
}

class _TierDialogState extends ConsumerState<_TierDialog> {
  final _formKey = GlobalKey<FormState>();
  late final _code = TextEditingController(
    text: '${widget.tier?['code'] ?? ''}',
  );
  late final _name = TextEditingController(
    text: '${widget.tier?['name'] ?? ''}',
  );
  late final _min = TextEditingController(
    text: '${(widget.tier?['min_points'] as num?)?.toInt() ?? 0}',
  );
  late final _mult = TextEditingController(
    text: widget.tier == null
        ? '1'
        : Fmt.toDouble(widget.tier!['multiplier']).toString(),
  );
  bool _saving = false;

  @override
  void dispose() {
    for (final c in [_code, _name, _min, _mult]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);
    final repo = ref.read(repoProvider);
    if (repo == null) return;

    final ok = await runWithFeedback(
      context,
      successMessage: 'Tier saved',
      action: () => repo.saveLoyaltyTier(
        programId: widget.programId,
        id: widget.tier?['id'] as String?,
        code: _code.text.trim(),
        name: _name.text.trim(),
        minPoints: int.tryParse(_min.text.trim()) ?? 0,
        multiplier: double.tryParse(_mult.text.trim()) ?? 1,
        // Editing a retired band brings it back, the same way an answer
        // to a modifier question does.
        isActive: true,
      ),
    );

    if (mounted) setState(() => _saving = false);
    if (ok && mounted) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.tier == null ? 'New tier' : 'Edit tier'),
      content: SizedBox(
        width: 420,
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Expanded(
                    child: TextFormField(
                      controller: _code,
                      decoration: const InputDecoration(labelText: 'Code *'),
                      validator: (v) =>
                          (v ?? '').trim().isEmpty ? 'Required' : null,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    flex: 2,
                    child: TextFormField(
                      controller: _name,
                      decoration: const InputDecoration(
                        labelText: 'Name *',
                        hintText: 'Emas',
                      ),
                      validator: (v) =>
                          (v ?? '').trim().isEmpty ? 'Required' : null,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _min,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'From this many points earned',
                  helperText:
                      'Earned, not held — redeeming never costs a tier.',
                ),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _mult,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: const InputDecoration(
                  labelText: 'Earns at',
                  suffixText: '× the plain rate',
                  helperText: 'One is the plain rate. 1.5 is half again.',
                ),
                validator: (v) {
                  final n = double.tryParse((v ?? '').trim());
                  if (n == null) return 'A number';
                  // A tier that earns nothing is a punishment dressed as
                  // a reward; the server refuses it too.
                  if (n <= 0) return 'Above nought';
                  return null;
                },
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: const Text('Save'),
        ),
      ],
    );
  }
}
