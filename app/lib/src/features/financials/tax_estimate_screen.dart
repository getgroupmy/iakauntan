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
    ref.invalidate(taxFirstPeriodProvider(widget.estimateId));
    ref.invalidate(taxInstalmentSummaryProvider(widget.estimateId));
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

              _FirstPeriod(id: id),

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
              _PaidSoFar(id: id),
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

  Future<void> _pay(
    BuildContext context,
    WidgetRef ref,
    TaxInstalment r,
  ) async {
    // An instalment a downward revision reduced to nothing has
    // nothing to pay, and offering to record a payment against it
    // would be offering to record nothing.
    if (r.amount == 0 && !r.isPaid) return;

    if (r.isPaid) {
      final undo = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text('Instalment ${r.number}'),
          content: Text(
            'Recorded as paid'
            '${r.paidOn == null ? '' : ' on ${Fmt.date(r.paidOn!)}'}'
            '${r.paidAmount == null ? '' : ', ${Fmt.money(r.paidAmount!)}'}'
            '. Unrecord it?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Keep it'),
            ),
            FilledButton(
              key: const ValueKey('instalment-unpay'),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Unrecord'),
            ),
          ],
        ),
      );
      if (undo != true || !context.mounted) return;
      final done = await runWithFeedback(
        context,
        doing: 'unrecord the payment',
        successMessage: 'Unrecorded',
        action: () => ref.read(repoProvider)!.clearTaxInstalment(
          estimateId: id,
          instalmentNo: r.number,
        ),
      );
      if (done) {
        ref.invalidate(taxEstimateScheduleProvider(id));
        ref.invalidate(taxInstalmentSummaryProvider(id));
      }
      return;
    }

    final paid = await showDialog<bool>(
      context: context,
      builder: (_) => _PayDialog(id: id, instalment: r),
    );
    if (paid == true) {
      ref.invalidate(taxEstimateScheduleProvider(id));
      ref.invalidate(taxInstalmentSummaryProvider(id));
    }
  }

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
              InkWell(
                key: ValueKey('instalment-tap-${r.number}'),
                onTap: () => _pay(context, ref, r),
                child: Padding(
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
                      child: Row(
                        children: [
                          Text(
                            r.dueOn == null ? '' : Fmt.date(r.dueOn!),
                          ),
                          // A revised schedule has two kinds of row in
                          // it, and the reader is entitled to know
                          // which they are looking at: the early ones
                          // were payable at the old figure on dates
                          // that have passed.
                          if (r.isWaived)
                            Padding(
                              padding: const EdgeInsets.only(left: Space.sm),
                              child: Text(
                                'nothing to pay',
                                key: ValueKey('instalment-waived-${r.number}'),
                                style: TextStyle(
                                  fontSize: 11,
                                  color: scheme.onSurfaceVariant,
                                ),
                              ),
                            )
                          else if (r.setByRevision)
                            Padding(
                              padding: const EdgeInsets.only(left: Space.sm),
                              child: Text(
                                'revised',
                                key: ValueKey('instalment-revised-${r.number}'),
                                style: TextStyle(
                                  fontSize: 11,
                                  color: scheme.tertiary,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(
                          Fmt.money(r.amount),
                          style: TextStyle(
                            decoration: r.isPaid && !r.isPartlyPaid
                                ? TextDecoration.lineThrough
                                : null,
                            color: r.isPaid && !r.isPartlyPaid
                                ? scheme.onSurfaceVariant
                                : null,
                          ),
                        ),
                        if (r.isPartlyPaid)
                          Text(
                            '${Fmt.money(r.outstanding)} short',
                            key: ValueKey('instalment-short-${r.number}'),
                            style: TextStyle(
                              fontSize: 11,
                              color: scheme.error,
                            ),
                          )
                        else if (r.paidLate)
                          Text(
                            'paid late',
                            key: ValueKey('instalment-late-${r.number}'),
                            style: TextStyle(
                              fontSize: 11,
                              color: scheme.error,
                            ),
                          )
                        else if (r.isPaid)
                          Text(
                            r.paidOn == null
                                ? 'paid'
                                : 'paid ${Fmt.date(r.paidOn!)}',
                            key: ValueKey('instalment-paid-${r.number}'),
                            style: TextStyle(
                              fontSize: 11,
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
                ),
              ),
            const Divider(),
            // The cast. An instalment plan that does not total the
            // thing it pays is the first thing anybody notices, so the
            // total is shown rather than assumed.
            //
            // After a DOWNWARD revision it deliberately does not come
            // to the estimate: the year owes less than has already
            // been billed, the remaining instalments are nil, and the
            // excess comes back at assessment rather than through the
            // schedule.
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
  final _capital = TextEditingController();
  final _income = TextEditingController();
  bool _seeded = false;
  bool _firstPeriod = false;
  DateTime? _commencedOn;

  @override
  void dispose() {
    _estimate.dispose();
    _prior.dispose();
    _capital.dispose();
    _income.dispose();
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
    _firstPeriod = row['first_period'] == true;
    _commencedOn = Fmt.parseDate(row['commenced_on']);
    // Blank rather than "0.00" for the same reason as the prior
    // estimate: a paid-up capital of nothing would pass the SME test
    // on a figure nobody supplied.
    _capital.text = row['paid_up_capital'] == null
        ? ''
        : Fmt.toDouble(row['paid_up_capital']).toStringAsFixed(2);
    _income.text = row['gross_business_income'] == null
        ? ''
        : Fmt.toDouble(row['gross_business_income']).toStringAsFixed(2);
  }

  double? _figure(TextEditingController c) {
    final text = c.text.trim().replaceAll(',', '');
    return text.isEmpty ? null : double.tryParse(text);
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
        'first_period': _firstPeriod,
        // Cleared along with the flag. A commencement date left behind
        // on a company that is no longer a first period would sit
        // there waiting to be believed the next time somebody ticked
        // the box.
        'commenced_on': !_firstPeriod || _commencedOn == null
            ? null
            : Fmt.iso(_commencedOn!),
        'paid_up_capital': _firstPeriod ? _figure(_capital) : null,
        'gross_business_income': _firstPeriod ? _figure(_income) : null,
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
                const SizedBox(height: Space.md),
                const Divider(),
                // Nothing infers this. The obvious rule -- the
                // company's first financial year in this product --
                // is wrong for every company that migrated in with
                // years of history behind it, and applying the
                // new-company rules to one of those would move a real
                // deadline and cancel real instalments.
                SwitchListTile(
                  key: const ValueKey('estimate-first-toggle'),
                  contentPadding: EdgeInsets.zero,
                  value: _firstPeriod,
                  onChanged: (v) => setState(() => _firstPeriod = v),
                  title: const Text('This is the first basis period'),
                  subtitle: const Text(
                    'A new business, not a new set of books. Nothing '
                    'can work this out on its own.',
                    style: TextStyle(fontSize: 11),
                  ),
                ),
                if (_firstPeriod) ...[
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          _commencedOn == null
                              ? 'Commenced operations: not set'
                              : 'Commenced ${Fmt.date(_commencedOn!)}',
                          key: const ValueKey('estimate-commenced'),
                        ),
                      ),
                      TextButton(
                        key: const ValueKey('estimate-pick-commenced'),
                        onPressed: () async {
                          final picked = await showDatePicker(
                            context: context,
                            initialDate: _commencedOn ?? DateTime.now(),
                            firstDate: DateTime(2000),
                            lastDate: DateTime(2100),
                          );
                          if (picked != null) {
                            setState(() => _commencedOn = picked);
                          }
                        },
                        child: const Text('Set'),
                      ),
                    ],
                  ),
                  Text(
                    'Not the incorporation date — a company '
                    'incorporated in March may commence in September, '
                    'and the deadline counts from the second.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: Space.md),
                  TextField(
                    key: const ValueKey('estimate-capital'),
                    controller: _capital,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(
                      labelText: 'Paid-up ordinary share capital',
                      prefixText: 'RM ',
                      helperText: 'At the START of the basis period. '
                          'Leave blank if unknown — blank schedules the '
                          'instalments rather than assuming there are '
                          'none.',
                      helperMaxLines: 3,
                    ),
                  ),
                  const SizedBox(height: Space.md),
                  TextField(
                    key: const ValueKey('estimate-income'),
                    controller: _income,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(
                      labelText: 'Gross business income',
                      prefixText: 'RM ',
                      helperText: 'Both figures are needed before the '
                          'exemption can be tested at all.',
                      helperMaxLines: 2,
                    ),
                  ),
                ],
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

/// How a first basis period differs.
///
/// Drawn only when the estimate says it IS one — an ordinary company
/// should not be shown a panel about rules that do not apply to it.
/// Inside, two answers and one question:
///
///   * the deadline, three months from commencing operations, beside
///     the ordinary one it replaces — which for a company incorporated
///     partway through a year has usually already passed, and seeing
///     that is the point;
///   * whether a qualifying new SME owes instalments at all;
///   * and where the two figures that decide it have not been typed,
///     a plain statement that the test could not be taken, because the
///     instalments are scheduled meanwhile and somebody should know
///     why.
class _FirstPeriod extends ConsumerWidget {
  const _FirstPeriod({required this.id});

  final String id;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    return AsyncView(
      value: ref.watch(taxFirstPeriodProvider(id)),
      onRetry: () => ref.invalidate(taxFirstPeriodProvider(id)),
      skeleton: const CardRowsSkeleton(
        rows: 2,
        leading: false,
        lines: 1,
        trailing: 1,
        trailingWidth: 100,
      ),
      builder: (fp) {
        if (!fp.isFirstPeriod) return const SizedBox.shrink();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const TaxSection(
              title: 'The first basis period',
              hint: 'Different deadline, and possibly no instalments',
            ),
            if (fp.filingDueKnown)
              _Notice(
                key: const ValueKey('estimate-first-due'),
                colour: scheme.surfaceContainerHighest,
                onColour: scheme.onSurface,
                icon: Icons.event_outlined,
                text:
                    'Due ${Fmt.date(fp.filingDue!)} — three months from '
                    'commencing operations'
                    '${fp.commencedOn == null ? '' : ' on '
                        '${Fmt.date(fp.commencedOn!)}'}. '
                    '${fp.ordinaryDateHasPassed
                        ? 'The ordinary date, '
                          '${Fmt.date(fp.ordinaryFilingDue!)}, passed '
                          'before this company existed — it is not the '
                          'one to work to.'
                        : ''}',
              )
            else
              _Notice(
                key: const ValueKey('estimate-first-nodate'),
                colour: scheme.surfaceContainerHighest,
                onColour: scheme.onSurface,
                icon: Icons.help_outline,
                text:
                    'The deadline runs three months from the day the '
                    'business commenced operations, which nobody has '
                    'entered. Enter it and the date appears — it is not '
                    'the incorporation date.',
              ),
            if (fp.exemptInstalments)
              _Notice(
                key: const ValueKey('estimate-exempt'),
                colour: scheme.surfaceContainerHighest,
                onColour: scheme.onSurface,
                icon: Icons.check_circle_outline,
                text:
                    'No instalments are payable. A qualifying new SME '
                    'is relieved of them'
                    '${fp.exemptUntilYa == null ? '' : ' through year of '
                        'assessment ${fp.exemptUntilYa}'}. '
                    'The estimate is still furnished.',
              )
            else if (fp.exemptionUntested)
              _Notice(
                key: const ValueKey('estimate-exempt-untested'),
                colour: scheme.surfaceContainerHighest,
                onColour: scheme.onSurface,
                icon: Icons.help_outline,
                text:
                    'Whether instalments are payable at all has not '
                    'been checked: it needs the paid-up capital at the '
                    'start of the period and the gross business income, '
                    'and neither is a figure this system holds. The '
                    'instalments below are scheduled meanwhile — the '
                    'safe way round, because missing one that was due '
                    'is a penalty.',
              )
            else
              _Notice(
                key: const ValueKey('estimate-not-exempt'),
                colour: scheme.surfaceContainerHighest,
                onColour: scheme.onSurface,
                icon: Icons.info_outline,
                text:
                    'Instalments are payable: the company is over the '
                    'limit for the new-SME relief'
                    '${fp.capitalLimit == null ? '' : ' '
                        '(${Fmt.money(fp.capitalLimit!)} of capital, '
                        '${Fmt.money(fp.turnoverLimit ?? 0)} of gross '
                        'income)'}.',
              ),
          ],
        );
      },
    );
  }
}

/// Recording one instalment as paid.
///
/// Both fields come pre-filled with the ordinary answer — today, and
/// the scheduled figure — because paying what was asked for on the day
/// is what almost always happened, and retyping a figure is a chance
/// to mistype it. Both are editable, because LHDN accepts what it is
/// sent and a short payment is a real thing that needs recording as
/// what it was.
class _PayDialog extends ConsumerStatefulWidget {
  const _PayDialog({required this.id, required this.instalment});

  final String id;
  final TaxInstalment instalment;

  @override
  ConsumerState<_PayDialog> createState() => _PayDialogState();
}

class _PayDialogState extends ConsumerState<_PayDialog> {
  late final TextEditingController _amount = TextEditingController(
    text: widget.instalment.amount.toStringAsFixed(2),
  );
  final _reference = TextEditingController();
  late DateTime _paidOn = DateTime.now();

  @override
  void dispose() {
    _amount.dispose();
    _reference.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final amount = double.tryParse(_amount.text.trim().replaceAll(',', ''));
    if (amount == null || amount < 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter what was paid.')),
      );
      return;
    }
    final done = await runWithFeedback(
      context,
      doing: 'record the payment',
      successMessage: 'Recorded',
      action: () => ref.read(repoProvider)!.recordTaxInstalment(
        estimateId: widget.id,
        instalmentNo: widget.instalment.number,
        paidOn: _paidOn,
        amount: amount,
        reference: _reference.text.trim().isEmpty
            ? null
            : _reference.text.trim(),
      ),
    );
    if (done && mounted) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.instalment;
    final late = r.dueOn != null && _paidOn.isAfter(r.dueOn!);
    return AlertDialog(
      title: Text('Instalment ${r.number}'),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (r.dueOn != null)
              Text(
                'Due ${Fmt.date(r.dueOn!)}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            const SizedBox(height: Space.md),
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Paid ${Fmt.date(_paidOn)}',
                    key: const ValueKey('pay-date'),
                  ),
                ),
                TextButton(
                  key: const ValueKey('pay-pick-date'),
                  onPressed: () async {
                    final picked = await showDatePicker(
                      context: context,
                      initialDate: _paidOn,
                      firstDate: DateTime(2000),
                      lastDate: DateTime(2100),
                    );
                    if (picked != null) setState(() => _paidOn = picked);
                  },
                  child: const Text('Change'),
                ),
              ],
            ),
            // Said before it is recorded rather than after. A tenth of
            // the instalment is a real charge and somebody choosing
            // the date should see it as they choose.
            if (late)
              Padding(
                padding: const EdgeInsets.only(top: Space.xs),
                child: Text(
                  'After the due date — s.107C(9) adds 10% of the '
                  'instalment.',
                  key: const ValueKey('pay-late-warning'),
                  style: TextStyle(
                    fontSize: 11,
                    color: Theme.of(context).colorScheme.error,
                  ),
                ),
              ),
            const SizedBox(height: Space.md),
            TextField(
              key: const ValueKey('pay-amount'),
              controller: _amount,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(
                labelText: 'Amount paid',
                prefixText: 'RM ',
                helperText: 'LHDN accepts what it is sent. A short '
                    'payment is recorded as what it was and the '
                    'shortfall stays outstanding.',
                helperMaxLines: 3,
              ),
            ),
            const SizedBox(height: Space.md),
            TextField(
              key: const ValueKey('pay-reference'),
              controller: _reference,
              decoration: const InputDecoration(
                labelText: 'Receipt or reference',
              ),
            ),
            const SizedBox(height: Space.md),
            Text(
              'A note that money moved. Nothing here posts to the '
              'ledger — the bank side is a bank transaction like any '
              'other.',
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
        FilledButton(
          key: const ValueKey('pay-save'),
          onPressed: _save,
          child: const Text('Record'),
        ),
      ],
    );
  }
}

/// Where the instalment year stands, above the rows it summarises.
///
/// Two things here are separate on purpose. **Overdue** is money that
/// should already have been sent — the thing to act on today.
/// **Late** is money that was sent, but after its date, and it carries
/// its own charge under s.107C(9) whether or not anything is overdue
/// now. A company can be completely up to date and still owe a penalty
/// on the three it paid a week behind.
class _PaidSoFar extends ConsumerWidget {
  const _PaidSoFar({required this.id});

  final String id;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    return AsyncView(
      value: ref.watch(taxInstalmentSummaryProvider(id)),
      onRetry: () => ref.invalidate(taxInstalmentSummaryProvider(id)),
      skeleton: const CardRowsSkeleton(
        rows: 2,
        leading: false,
        lines: 1,
        trailing: 1,
        trailingWidth: 90,
      ),
      builder: (s) {
        if (s.instalments == 0) return const SizedBox.shrink();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.only(bottom: Space.sm),
              child: Text(
                '${s.instalmentsPaid} of ${s.instalments} recorded as '
                'paid — ${Fmt.money(s.paidTotal)} of '
                '${Fmt.money(s.scheduledTotal)}',
                key: const ValueKey('instalments-paid-so-far'),
                style: TextStyle(
                  fontSize: 12,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
            if (s.isBehind)
              _Notice(
                key: const ValueKey('instalments-overdue'),
                colour: scheme.errorContainer,
                onColour: scheme.onErrorContainer,
                icon: Icons.error_outline,
                text:
                    '${s.overdueCount} instalment'
                    '${s.overdueCount == 1 ? '' : 's'} past due and '
                    'unrecorded, ${Fmt.money(s.overdueTotal)} in all. '
                    'Each one carries 10% of itself once it is late.',
              )
            else if (s.nextDueOn != null)
              Padding(
                padding: const EdgeInsets.only(bottom: Space.sm),
                child: Text(
                  'Next: ${Fmt.money(s.nextDueAmount ?? 0)} on '
                  '${Fmt.date(s.nextDueOn!)}',
                  key: const ValueKey('instalments-next-due'),
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: scheme.onSurface,
                  ),
                ),
              )
            else if (s.allPaid)
              Padding(
                padding: const EdgeInsets.only(bottom: Space.sm),
                child: Text(
                  'Every instalment recorded as paid.',
                  key: const ValueKey('instalments-all-paid'),
                  style: TextStyle(
                    fontSize: 12,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
            // Separate from overdue, and stated even when nothing is
            // outstanding: a company entirely up to date still owes
            // this on whatever it sent behind time.
            if (s.lateCount > 0)
              _Notice(
                key: const ValueKey('instalments-late-penalty'),
                colour: scheme.surfaceContainerHighest,
                onColour: scheme.onSurface,
                icon: Icons.schedule,
                text:
                    '${s.lateCount} instalment'
                    '${s.lateCount == 1 ? ' was' : 's were'} paid after '
                    'the due date. s.107C(9) adds '
                    '${Fmt.money(s.latePenalty)} — this says what the '
                    'charge comes to, not that LHDN has raised it.',
              ),
          ],
        );
      },
    );
  }
}
