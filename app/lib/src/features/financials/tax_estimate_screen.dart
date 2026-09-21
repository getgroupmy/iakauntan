import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/skeletons.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/models.dart';
import 'tax_computation_screen.dart' show TaxLine, TaxSection;

/// CP204: the estimate, before it becomes a penalty.
///
/// `0665` computes what is owed once the year has finished. This is the
/// other half of the year, running the opposite way — a company says
/// what it thinks it will owe BEFORE the basis period begins, pays that
/// monthly, and is penalised if it guessed too low.
///
/// The penalty is why this screen exists. Under-estimate by more than
/// the tolerance and a tenth of the excess is added to the bill, on a
/// figure this system already knows how to compute. So the screen's job
/// is to say so in the sixth month, when a revision is still allowed,
/// rather than in the assessment.
class TaxEstimateScreen extends ConsumerStatefulWidget {
  const TaxEstimateScreen({
    super.key,
    required this.estimateId,
    this.computationId,
  });

  final String estimateId;

  /// The Form C to measure against, where the year has run far enough
  /// for one to exist. Null for most of the year, and the screen says
  /// what it cannot answer rather than answering it with zero.
  final String? computationId;

  @override
  ConsumerState<TaxEstimateScreen> createState() =>
      _TaxEstimateScreenState();
}

class _TaxEstimateScreenState extends ConsumerState<TaxEstimateScreen> {
  ({String estimate, String? computation}) get _key =>
      (estimate: widget.estimateId, computation: widget.computationId);

  void _reload() {
    ref.invalidate(taxEstimateProvider(widget.estimateId));
    ref.invalidate(taxEstimateScheduleProvider(widget.estimateId));
    ref.invalidate(taxEstimateExposureProvider(_key));
  }

  Future<void> _edit() async {
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => _EstimateDialog(id: widget.estimateId),
    );
    if (saved == true) _reload();
  }

  Future<void> _revise() async {
    final made = await showDialog<String?>(
      context: context,
      builder: (_) => _ReviseDialog(id: widget.estimateId),
    );
    if (made == null || !mounted) return;
    // The revision is a NEW estimate, so this screen is looking at a
    // superseded one. Replace the route rather than pushing: going
    // "back" to a superseded estimate is going back to a figure that
    // no longer applies.
    Navigator.of(context).pushReplacement(
      MaterialPageRoute<void>(
        builder: (_) => TaxEstimateScreen(
          estimateId: made,
          computationId: widget.computationId,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final exposure = ref.watch(taxEstimateExposureProvider(_key));

    return Scaffold(
      appBar: AppBar(
        // The form, not a generic word for it. A person paying CP500
        // and a company paying CP204 are looking at two different
        // documents on two different rhythms, and the title is the
        // first place that can say so.
        title: Text(
          exposure.valueOrNull == null
              ? 'Tax estimate'
              : '${exposure.valueOrNull!.form} estimate',
        ),
        actions: [
          IconButton(
            key: const ValueKey('estimate-edit'),
            tooltip: 'Change the estimate',
            icon: const Icon(Icons.edit_outlined),
            onPressed: _edit,
          ),
          IconButton(
            key: const ValueKey('estimate-revise'),
            tooltip: 'Revise it (CP204A)',
            icon: const Icon(Icons.published_with_changes),
            onPressed: _revise,
          ),
        ],
      ),
      body: AsyncView(
        value: exposure,
        onRetry: () => ref.invalidate(taxEstimateExposureProvider(_key)),
        skeleton: const Padding(
          padding: EdgeInsets.all(Space.lg),
          child: CardRowsSkeleton(
            rows: 8,
            leading: false,
            lines: 1,
            trailing: 1,
            trailingWidth: 100,
          ),
        ),
        builder: (e) => _Estimate(id: widget.estimateId, e: e),
      ),
    );
  }
}

class _Estimate extends ConsumerWidget {
  const _Estimate({required this.id, required this.e});

  final String id;
  final TaxEstimateExposure e;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;

    return ListView(
      padding: const EdgeInsets.all(Space.lg),
      children: [
        PageBody(
          maxWidth: 820,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // The one state worth interrupting somebody for: money is
              // at stake AND there is still a month in which to fix it.
              if (e.canStillFix)
                _Notice(
                  key: const ValueKey('estimate-fixable'),
                  colour: scheme.errorContainer,
                  onColour: scheme.onErrorContainer,
                  icon: Icons.warning_amber_outlined,
                  text:
                      'This estimate is ${Fmt.money(e.shortfall ?? 0)} '
                      'under what the year actually owes, which is '
                      '${Fmt.money(e.penalty ?? 0)} of penalty — and a '
                      'revision is allowed THIS month. Revising now is '
                      'the difference.',
                )
              else if (e.isExposed)
                _Notice(
                  key: const ValueKey('estimate-exposed'),
                  colour: scheme.errorContainer,
                  onColour: scheme.onErrorContainer,
                  icon: Icons.error_outline,
                  text:
                      'Under-estimated by ${Fmt.money(e.shortfall ?? 0)}, '
                      'which is ${Fmt.money(e.penalty ?? 0)} of penalty. '
                      'A revision is only allowed in '
                      '${_months(e.revisionMonths)} of the basis period.',
                ),

              // Missing the floor is a different failure: the estimate
              // is not low, it is invalid, and LHDN substitutes its own.
              //
              // Three states, not two. A CP500 has no floor at all --
              // LHDN issues it rather than the taxpayer proposing a
              // figure -- so `missesFloor` is what decides this rather
              // than `!meetsFloor`, which is also false when the rule
              // does not exist.
              if (e.missesFloor)
                _Notice(
                  key: const ValueKey('estimate-floor'),
                  colour: scheme.errorContainer,
                  onColour: scheme.onErrorContainer,
                  icon: Icons.block,
                  text:
                      'Below the floor. An estimate must be at least '
                      '${Fmt.money(e.floorRequired ?? 0)} — the required '
                      'share of last year’s — or it is not accepted '
                      'and a figure is substituted.',
                )
              else if (e.floorApplies && !e.floorKnown)
                _Notice(
                  key: const ValueKey('estimate-floor-unknown'),
                  colour: scheme.surfaceContainerHighest,
                  onColour: scheme.onSurface,
                  icon: Icons.help_outline,
                  text:
                      'Last year’s estimate has not been entered, so '
                      'whether this one clears the floor cannot be '
                      'checked. Enter it and the answer appears.',
                )
              else if (!e.floorApplies)
                _Notice(
                  key: const ValueKey('estimate-floor-none'),
                  colour: scheme.surfaceContainerHighest,
                  onColour: scheme.onSurface,
                  icon: Icons.info_outline,
                  text:
                      'A CP500 has no floor against last year. LHDN '
                      'issues the estimate from the previous '
                      'assessment and you apply to revise it — so '
                      'there is nothing here for an estimate to be too '
                      'low against. The penalty below is a separate '
                      'question and still applies.',
                ),

              TaxSection(title: 'The ${e.form} estimate'),
              TaxLine('Estimated tax', e.estimatedTax, bold: true),
              if (e.floorApplies && e.floorKnown) ...[
                TaxLine('Last year’s estimate', e.priorEstimate ?? 0),
                TaxLine(
                  'The least this year may be',
                  e.floorRequired ?? 0,
                  hint: e.meetsFloor
                      ? 'Cleared'
                      : 'NOT cleared — the estimate is invalid',
                  warn: !e.meetsFloor,
                ),
              ],

              const TaxSection(
                title: 'Against what the year actually owes',
                hint: 'The other question entirely — an estimate can '
                    'clear the floor and still be penalised',
              ),
              if (!e.actualKnown)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: Space.sm),
                  child: Text(
                    'Not known yet. Once the year has run far enough for '
                    'a computation, the shortfall and what it costs '
                    'appear here — ideally before the last month a '
                    'revision is allowed in.',
                    style: TextStyle(
                      fontSize: 12,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                )
              else ...[
                TaxLine('Tax actually owed', e.actualTax ?? 0),
                TaxLine('Under-estimated by', e.shortfall ?? 0),
                TaxLine(
                  'Allowed to be under by',
                  e.toleranceAmount ?? 0,
                  hint: 'A share of what was owed, not of the estimate',
                ),
                TaxLine('Excess beyond that', e.excessOverTolerance ?? 0),
                const Divider(),
                TaxLine(
                  'Penalty',
                  e.penalty ?? 0,
                  bold: true,
                  warn: (e.penalty ?? 0) > 0,
                ),
              ],

              const SizedBox(height: Space.lg),
              const TaxSection(title: 'Instalments'),
              _Schedule(id: id),

              const SizedBox(height: Space.lg),
              Text(
                'A working, not a filing. Nothing here is sent to LHDN '
                'and no instalment is paid from here. A revision is '
                'allowed in ${_months(e.revisionMonths)} of the basis '
                'period; this records one whenever you make it, because '
                'a late revision is sometimes still worth recording.',
                style: TextStyle(
                  fontSize: 12,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  static String _months(List<int> months) {
    if (months.isEmpty) return 'no month';
    if (months.length == 1) return 'month ${months.first}';
    final all = months.map((m) => '$m').toList();
    return 'months ${all.sublist(0, all.length - 1).join(', ')} '
        'and ${all.last}';
  }
}

class _Schedule extends ConsumerWidget {
  const _Schedule({required this.id});

  final String id;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    return AsyncView(
      value: ref.watch(taxEstimateScheduleProvider(id)),
      onRetry: () => ref.invalidate(taxEstimateScheduleProvider(id)),
      skeleton: const CardRowsSkeleton(
        rows: 6,
        leading: false,
        lines: 1,
        trailing: 1,
        trailingWidth: 90,
      ),
      builder: (rows) {
        if (rows.isEmpty) {
          return Text(
            'No instalments — the estimate is nothing.',
            style: TextStyle(
              fontSize: 12,
              color: scheme.onSurfaceVariant,
            ),
          );
        }
        final total = rows.fold<double>(0, (s, r) => s + r.amount);
        return Column(
          children: [
            for (final r in rows)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  key: ValueKey('instalment-${r.number}'),
                  children: [
                    SizedBox(
                      width: 32,
                      child: Text(
                        '${r.number}',
                        style: TextStyle(
                          fontSize: 12,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                    Expanded(
                      child: Text(
                        r.dueOn == null ? '' : Fmt.date(r.dueOn!),
                      ),
                    ),
                    Text(Fmt.money(r.amount)),
                  ],
                ),
              ),
            const Divider(),
            // The cast. An instalment plan that does not total the
            // thing it pays is the first thing anybody notices, so the
            // total is shown rather than assumed.
            Row(
              children: [
                const SizedBox(width: 32),
                const Expanded(
                  child: Text(
                    'In all',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                Text(
                  Fmt.money(total),
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ],
            ),
          ],
        );
      },
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({
    super.key,
    required this.colour,
    required this.onColour,
    required this.icon,
    required this.text,
  });

  final Color colour;
  final Color onColour;
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.only(bottom: Space.md),
    padding: const EdgeInsets.all(Space.md),
    decoration: BoxDecoration(
      color: colour,
      borderRadius: BorderRadius.circular(Radii.md),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 18, color: onColour),
        const SizedBox(width: Space.sm),
        Expanded(
          child: Text(
            text,
            style: TextStyle(fontSize: 12, color: onColour),
          ),
        ),
      ],
    ),
  );
}

class _EstimateDialog extends ConsumerStatefulWidget {
  const _EstimateDialog({required this.id});

  final String id;

  @override
  ConsumerState<_EstimateDialog> createState() => _EstimateDialogState();
}

class _EstimateDialogState extends ConsumerState<_EstimateDialog> {
  final _estimate = TextEditingController();
  final _prior = TextEditingController();
  bool _seeded = false;

  @override
  void dispose() {
    _estimate.dispose();
    _prior.dispose();
    super.dispose();
  }

  void _seed(Map<String, dynamic>? row) {
    if (_seeded || row == null) return;
    _seeded = true;
    _estimate.text =
        Fmt.toDouble(row['estimated_tax']).toStringAsFixed(2);
    // Blank rather than "0.00" where it is unknown: a prior estimate of
    // nothing would make the floor nothing and pass any figure at all.
    _prior.text = row['prior_estimate'] == null
        ? ''
        : Fmt.toDouble(row['prior_estimate']).toStringAsFixed(2);
  }

  Future<void> _save() async {
    final estimate =
        double.tryParse(_estimate.text.trim().replaceAll(',', ''));
    if (estimate == null || estimate < 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter an estimate.')),
      );
      return;
    }
    final priorText = _prior.text.trim().replaceAll(',', '');
    final done = await runWithFeedback(
      context,
      doing: 'save the estimate',
      successMessage: 'Saved',
      action: () => ref.read(repoProvider)!.saveTaxEstimate(widget.id, {
        'estimated_tax': estimate,
        'prior_estimate':
            priorText.isEmpty ? null : double.tryParse(priorText),
      }),
    );
    if (done && mounted) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    final row = ref.watch(taxEstimateProvider(widget.id));
    return AlertDialog(
      title: const Text('The estimate'),
      content: SizedBox(
        width: 460,
        child: AsyncView(
          value: row,
          onRetry: () => ref.invalidate(taxEstimateProvider(widget.id)),
          skeleton: const FormSkeleton(fields: 2),
          builder: (r) {
            _seed(r);
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  key: const ValueKey('estimate-amount'),
                  controller: _estimate,
                  autofocus: true,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(
                    labelText: 'Tax estimated for this year',
                    prefixText: 'RM ',
                  ),
                ),
                const SizedBox(height: Space.md),
                TextField(
                  key: const ValueKey('estimate-prior'),
                  controller: _prior,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(
                    labelText: 'Last year’s estimate',
                    prefixText: 'RM ',
                    helperText: 'The revised one, where there was a '
                        'revision. Leave blank if there was no estimate '
                        'last year — blank means unknown, not nothing.',
                    helperMaxLines: 3,
                  ),
                ),
              ],
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _save, child: const Text('Save')),
      ],
    );
  }
}

class _ReviseDialog extends ConsumerStatefulWidget {
  const _ReviseDialog({required this.id});

  final String id;

  @override
  ConsumerState<_ReviseDialog> createState() => _ReviseDialogState();
}

class _ReviseDialogState extends ConsumerState<_ReviseDialog> {
  final _amount = TextEditingController();

  @override
  void dispose() {
    _amount.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final amount = double.tryParse(_amount.text.trim().replaceAll(',', ''));
    if (amount == null || amount < 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter the revised estimate.')),
      );
      return;
    }
    String? newId;
    final done = await runWithFeedback(
      context,
      doing: 'revise the estimate',
      successMessage: 'Revised',
      action: () async {
        newId = await ref
            .read(repoProvider)!
            .reviseTaxEstimate(widget.id, amount);
      },
    );
    if (done && newId != null && mounted) Navigator.pop(context, newId);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Revise the estimate'),
    content: SizedBox(
      width: 460,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            key: const ValueKey('revise-amount'),
            controller: _amount,
            autofocus: true,
            keyboardType:
                const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(
              labelText: 'Revised estimate',
              prefixText: 'RM ',
            ),
          ),
          const SizedBox(height: Space.md),
          Text(
            'This keeps the original rather than changing it — CP204A '
            'is its own form, and next year’s floor is measured '
            'against the revised figure.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(onPressed: _save, child: const Text('Revise')),
    ],
  );
}
