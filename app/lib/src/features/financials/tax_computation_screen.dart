import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/skeletons.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/models.dart';

/// The Form C working, as an accountant reads it.
///
/// Top to bottom in the order the Act takes it, because that order is
/// the argument: profit, then what is added back, then what the
/// allowances take off, then the losses, then the rate. Every figure
/// is derived when the screen opens, so it cannot have drifted from
/// the ledger since somebody last looked.
///
/// ## What this is not
///
/// Not a filing. There is no submission here and no CP204 estimate.
/// This is the document an accountant reviews and then keys or
/// attaches, and it says so on the screen rather than leaving somebody
/// to discover it.
class TaxComputationScreen extends ConsumerWidget {
  const TaxComputationScreen({super.key, required this.computationId});

  final String computationId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final computation = ref.watch(taxComputationProvider(computationId));

    return Scaffold(
      appBar: AppBar(
        title: const Text('Tax computation'),
        actions: [
          IconButton(
            key: const ValueKey('tax-inputs'),
            tooltip: 'Figures the accounts cannot know',
            icon: const Icon(Icons.tune),
            onPressed: () => showTaxInputs(context, computationId),
          ),
        ],
      ),
      body: AsyncView(
        value: computation,
        onRetry: () => ref.invalidate(taxComputationProvider(computationId)),
        skeleton: const Padding(
          padding: EdgeInsets.all(Space.lg),
          child: CardRowsSkeleton(
            rows: 10,
            leading: false,
            lines: 1,
            trailing: 1,
            trailingWidth: 100,
          ),
        ),
        builder: (c) => _Computation(id: computationId, c: c),
      ),
    );
  }
}

class _Computation extends ConsumerWidget {
  const _Computation({required this.id, required this.c});

  final String id;
  final TaxComputation c;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final misfiled = ref.watch(taxMisfiledAccountsProvider).valueOrNull ?? [];

    return ListView(
      padding: const EdgeInsets.all(Space.lg),
      children: [
        PageBody(
          maxWidth: 820,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Year of assessment ${c.yearOfAssessment}',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              if (c.periodFrom != null && c.periodTo != null)
                Text(
                  'Basis period ${Fmt.date(c.periodFrom!)} '
                  'to ${Fmt.date(c.periodTo!)}',
                  style: TextStyle(
                    fontSize: 12,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              const SizedBox(height: Space.lg),

              // A treatment on the wrong side of the ledger drops its
              // line silently. The computation still balances and is
              // wrong by whatever that account holds, so it is said
              // loudly and first.
              if (misfiled.isNotEmpty)
                _Notice(
                  key: const ValueKey('tax-misfiled'),
                  colour: scheme.errorContainer,
                  onColour: scheme.onErrorContainer,
                  icon: Icons.error_outline,
                  text:
                      '${misfiled.length} account'
                      '${misfiled.length == 1 ? '' : 's'} '
                      '(${misfiled.map((m) => m['code']).join(', ')}) '
                      'carry a tax treatment meant for the other side of '
                      'the ledger. Those lines are left OUT of this '
                      'computation — the figures below are wrong by '
                      'whatever those accounts hold.',
                ),

              // The SME test, when it could not be taken. The standard
              // rate is charged, which may be right — but nobody has
              // checked, and a computation that does not say so reads
              // like one that did.
              if (!c.smeKnown)
                _Notice(
                  key: const ValueKey('tax-sme-unknown'),
                  colour: scheme.surfaceContainerHighest,
                  onColour: scheme.onSurface,
                  icon: Icons.help_outline,
                  text:
                      'Charged at the standard rate because the SME test '
                      'has not been taken. Enter the paid-up capital and '
                      'the gross business income to take it — the '
                      'preferential band is worth up to '
                      '${Fmt.money(10500)} a year.',
                ),

              _Section(title: 'From the accounts'),
              _Line('Profit before taxation', c.profitBeforeTax),

              _Section(title: 'Add'),
              _Line('Non-deductible expenses', c.addBacks),
              if (c.balancingCharge > 0)
                _Line('Balancing charge on disposals', c.balancingCharge),

              if (c.deductions > 0) ...[
                _Section(title: 'Less'),
                _Line('Non-taxable income', -c.deductions),
              ],

              const Divider(),
              if (c.hasLoss)
                _Line('Adjusted loss', c.adjustedLoss, bold: true,
                    warn: true)
              else
                _Line('Adjusted income', c.adjustedIncome, bold: true),

              _Section(title: 'Capital allowances'),
              _Line('This year (Schedule 3)', c.caCurrent),
              if (c.caBroughtForward > 0)
                _Line('Brought forward', c.caBroughtForward),
              _Line('Used against income', -c.caUsed),
              if (c.caCarriedForward > 0)
                _Line(
                  'Unabsorbed, carried forward',
                  c.caCarriedForward,
                  // Not a loss, and labelled so. The two carry forward
                  // under different rules and adding them together is
                  // the mistake this wording exists to prevent.
                  hint: 'Unabsorbed allowance — not a loss',
                ),

              const Divider(),
              _Line('Statutory income', c.statutoryIncome, bold: true),

              if (c.lossBroughtForward > 0) ...[
                _Section(title: 'Losses'),
                _Line('Brought forward', c.lossBroughtForward),
                _Line('Used', -c.lossUsed),
              ],
              if (c.lossCarriedForward > 0)
                _Line('Losses carried forward', c.lossCarriedForward,
                    hint: 'To next year'),

              const Divider(),
              _Line('Chargeable income', c.chargeableIncome, bold: true),

              _Section(
                title: 'Tax',
                hint: c.smeKnown
                    ? (c.isSme
                          ? 'At the SME bands'
                          : 'At the standard rate — the company does not '
                                'qualify for the preferential band')
                    : 'At the standard rate — the SME test has not been '
                          'taken',
              ),
              _Line('Tax charged', c.taxCharged),
              if (c.zakatRebate > 0)
                _Line('Zakat rebate', -c.zakatRebate,
                    hint: 'A rebate against the tax, capped at it'),
              if (c.s110TaxDeducted > 0)
                _Line('Tax deducted at source (s.110)', -c.s110TaxDeducted),
              if (c.cp204Paid > 0)
                _Line('CP204 instalments paid', -c.cp204Paid),

              const Divider(),
              _Line(
                c.isRefund ? 'Tax refundable' : 'Tax payable',
                c.isRefund ? -c.taxPayable : c.taxPayable,
                bold: true,
                warn: !c.isRefund && c.taxPayable > 0,
              ),

              const SizedBox(height: Space.lg),
              _Adjustments(id: id),

              const SizedBox(height: Space.lg),
              _Workings(id: id),

              const SizedBox(height: Space.lg),
              Text(
                'This is a working, not a filing. Nothing here is sent '
                'to LHDN. The rates and Schedule 3 figures were seeded '
                'from published summaries rather than transcribed from '
                'the Act — check them before you file.',
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
}

/// Every add-back and deduction, with the account behind it.
///
/// Collapsed by default. A reviewer reads the computation first and
/// asks "which account" second, and forty lines above the answer is
/// forty lines between them and it.
class _Workings extends ConsumerWidget {
  const _Workings({required this.id});

  final String id;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    return ExpansionTile(
      key: const ValueKey('tax-workings'),
      title: const Text('The working'),
      subtitle: const Text('Every line, and the account it came from'),
      children: [
        AsyncView(
          value: ref.watch(taxComputationLinesProvider(id)),
          onRetry: () => ref.invalidate(taxComputationLinesProvider(id)),
          skeleton: const CardRowsSkeleton(
            rows: 5,
            leading: false,
            trailing: 1,
            trailingWidth: 90,
          ),
          builder: (lines) {
            if (lines.isEmpty) {
              return const Padding(
                padding: EdgeInsets.all(Space.md),
                child: Text(
                  'Nothing is added back or taken out. Tag an account '
                  'with a tax treatment — depreciation, entertainment, '
                  'penalties — and it appears here.',
                ),
              );
            }
            return Column(
              children: [
                for (final l in lines)
                  ListTile(
                    key: ValueKey('tax-line-${l.kind}-${l.label}'),
                    dense: true,
                    title: Text(l.label),
                    subtitle: Text(
                      // "50% of 12,000" answers the question a bare
                      // 6,000 provokes, and only where it arises.
                      l.isPartial
                          ? '${l.source} · '
                                '${Fmt.qty(l.fraction * 100)}% of '
                                '${Fmt.money(l.gross)}'
                          : l.source,
                      style: TextStyle(color: scheme.onSurfaceVariant),
                    ),
                    trailing: Text(
                      l.isAddBack
                          ? Fmt.money(l.amount)
                          : '(${Fmt.money(l.amount)})',
                      style: TextStyle(
                        color: l.isAddBack ? null : scheme.primary,
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
      ],
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, this.hint});

  final String title;
  final String? hint;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: Space.lg, bottom: Space.xs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: Theme.of(context).textTheme.titleSmall,
          ),
          if (hint != null)
            Text(
              hint!,
              style: TextStyle(
                fontSize: 11,
                color: scheme.onSurfaceVariant,
              ),
            ),
        ],
      ),
    );
  }
}

class _Line extends StatelessWidget {
  const _Line(
    this.label,
    this.value, {
    this.bold = false,
    this.warn = false,
    this.hint,
  });

  final String label;
  final double value;
  final bool bold;
  final bool warn;
  final String? hint;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Negatives in brackets, which is how a schedule is read. A minus
    // sign at the front of a column of figures is easy to miss and
    // changes the sense of the line entirely.
    final text = value < 0
        ? '(${Fmt.money(-value)})'
        : Fmt.money(value);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    fontWeight: bold ? FontWeight.w600 : null,
                  ),
                ),
                if (hint != null)
                  Text(
                    hint!,
                    style: TextStyle(
                      fontSize: 11,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
          Text(
            text,
            style: TextStyle(
              fontWeight: bold ? FontWeight.w600 : null,
              color: warn ? scheme.error : null,
            ),
          ),
        ],
      ),
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

/// The figures the ledger cannot know.
///
/// Five numbers and two facts about the company. Everything else on the
/// computation is derived, and keeping this list short is the point:
/// each figure here is one a reviewer has to check against something
/// outside this system, and every one added is another.
Future<void> showTaxInputs(BuildContext context, String id) {
  return showDialog<void>(
    context: context,
    builder: (_) => _TaxInputsDialog(id: id),
  );
}

class _TaxInputsDialog extends ConsumerStatefulWidget {
  const _TaxInputsDialog({required this.id});

  final String id;

  @override
  ConsumerState<_TaxInputsDialog> createState() => _TaxInputsDialogState();
}

class _TaxInputsDialogState extends ConsumerState<_TaxInputsDialog> {
  final _controllers = <String, TextEditingController>{};
  bool _seeded = false;

  /// The column, the label, and what it is for. In the order the
  /// computation uses them, so somebody filling it in reads down.
  static const _fields = <({String key, String label, String hint})>[
    (
      key: 'paid_up_capital',
      label: 'Paid-up ordinary share capital',
      hint: 'At the BEGINNING of the basis period. Half of the SME test.',
    ),
    (
      key: 'gross_business_income',
      label: 'Gross business income',
      hint: 'For the basis period. The other half of the SME test.',
    ),
    (
      key: 'capital_allowance_bf',
      label: 'Unabsorbed capital allowances brought forward',
      hint: 'From last year’s computation. Not a loss.',
    ),
    (
      key: 'loss_bf',
      label: 'Losses brought forward',
      hint: 'Set against statutory income, after the allowances.',
    ),
    (
      key: 'zakat_paid',
      label: 'Zakat perniagaan paid',
      hint: 'A rebate against the tax, capped at it — s.6A(3).',
    ),
    (
      key: 's110_tax_deducted',
      label: 'Tax deducted at source (s.110)',
      hint: 'Already withheld on your behalf.',
    ),
    (
      key: 'cp204_paid',
      label: 'CP204 instalments paid',
      hint: 'What has already gone to LHDN this year.',
    ),
  ];

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _seed(Map<String, dynamic>? row) {
    if (_seeded || row == null) return;
    _seeded = true;
    for (final f in _fields) {
      final v = row[f.key];
      _controllers[f.key] = TextEditingController(
        // Blank rather than "0" for the two that may be UNKNOWN: a
        // zero paid-up capital would pass the SME test, and a form
        // that offers zero invites somebody to leave it.
        text: v == null ? '' : Fmt.toDouble(v).toStringAsFixed(2),
      );
    }
  }

  Future<void> _save() async {
    final changes = <String, dynamic>{};
    for (final f in _fields) {
      final text = _controllers[f.key]?.text.trim() ?? '';
      final parsed = double.tryParse(text.replaceAll(',', ''));
      if (text.isEmpty) {
        // Only the two SME figures are nullable; the rest are NOT NULL
        // with a default of zero, and sending null would be refused.
        changes[f.key] = _nullable(f.key) ? null : 0;
      } else if (parsed != null && parsed >= 0) {
        changes[f.key] = parsed;
      }
    }

    final ok = await runWithFeedback(
      context,
      doing: 'save the figures',
      successMessage: 'Saved',
      action: () =>
          ref.read(repoProvider)!.saveTaxComputation(widget.id, changes),
    );
    ref.invalidate(taxComputationProvider(widget.id));
    ref.invalidate(taxComputationRowProvider(widget.id));
    if (ok && mounted) Navigator.pop(context);
  }

  static bool _nullable(String key) =>
      key == 'paid_up_capital' || key == 'gross_business_income';

  @override
  Widget build(BuildContext context) {
    final row = ref.watch(taxComputationRowProvider(widget.id));

    return AlertDialog(
      title: const Text('Figures the accounts cannot know'),
      content: SizedBox(
        width: 520,
        child: AsyncView(
          value: row,
          onRetry: () =>
              ref.invalidate(taxComputationRowProvider(widget.id)),
          skeleton: const FormSkeleton(fields: 7),
          builder: (r) {
            _seed(r);
            return SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final f in _fields) ...[
                    TextField(
                      key: ValueKey('tax-input-${f.key}'),
                      controller: _controllers[f.key],
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      decoration: InputDecoration(
                        labelText: f.label,
                        helperText: f.hint,
                        helperMaxLines: 2,
                        prefixText: 'RM ',
                      ),
                    ),
                    const SizedBox(height: Space.md),
                  ],
                ],
              ),
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

/// The adjustments a tag on an account cannot make.
///
/// A director's private mileage inside a motor expenses account that
/// is otherwise deductible; a gain on disposal that is capital in
/// nature. Typed, with a reason beside each -- and visibly the
/// exceptions rather than the computation, which is why they sit under
/// their own heading with a count on it.
class _Adjustments extends ConsumerWidget {
  const _Adjustments({required this.id});

  final String id;

  Future<void> _add(BuildContext context, WidgetRef ref) async {
    final made = await showDialog<bool>(
      context: context,
      builder: (_) => _AdjustmentDialog(computationId: id),
    );
    if (made != true) return;
    ref.invalidate(taxAdjustmentsProvider(id));
    ref.invalidate(taxComputationProvider(id));
    ref.invalidate(taxComputationLinesProvider(id));
  }

  Future<void> _remove(
    BuildContext context,
    WidgetRef ref,
    Map<String, dynamic> row,
  ) async {
    final yes = await confirm(
      context,
      title: 'Remove this adjustment?',
      message:
          '${row['label']} — ${Fmt.money(Fmt.toDouble(row['amount']))}. '
          'The computation is recalculated without it.',
      confirmLabel: 'Remove',
      destructive: true,
    );
    if (!yes || !context.mounted) return;

    await runWithFeedback(
      context,
      doing: 'remove the adjustment',
      successMessage: 'Removed',
      action: () =>
          ref.read(repoProvider)!.removeTaxAdjustment(row['id'] as String),
    );
    ref.invalidate(taxAdjustmentsProvider(id));
    ref.invalidate(taxComputationProvider(id));
    ref.invalidate(taxComputationLinesProvider(id));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final canPost = ref.watch(canPostProvider);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Space.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Adjustments',
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                      Text(
                        'What a tag on an account cannot say',
                        style: TextStyle(
                          fontSize: 11,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                if (canPost)
                  TextButton.icon(
                    key: const ValueKey('tax-add-adjustment'),
                    onPressed: () => _add(context, ref),
                    icon: const Icon(Icons.add, size: 18),
                    label: const Text('Add'),
                  ),
              ],
            ),
            AsyncView(
              value: ref.watch(taxAdjustmentsProvider(id)),
              onRetry: () => ref.invalidate(taxAdjustmentsProvider(id)),
              skeleton: const CardRowsSkeleton(
                rows: 2,
                leading: false,
                trailing: 1,
                trailingWidth: 90,
              ),
              builder: (rows) {
                if (rows.isEmpty) {
                  return Padding(
                    padding: const EdgeInsets.only(top: Space.sm),
                    child: Text(
                      'None. Most computations need one or two — the '
                      'private half of a motor expense, a gain that is '
                      'capital in nature.',
                      style: TextStyle(
                        fontSize: 12,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  );
                }
                return Column(
                  children: [
                    for (final r in rows)
                      ListTile(
                        key: ValueKey('tax-adjustment-${r['id']}'),
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        title: Text(r['label']?.toString() ?? ''),
                        subtitle: Text(
                          // An adjustment with no reason is the line a
                          // reviewer stops at, so the absence is said
                          // rather than left blank.
                          (r['reason']?.toString().trim().isNotEmpty ??
                                  false)
                              ? r['reason'].toString()
                              : 'No reason given',
                          style: TextStyle(color: scheme.onSurfaceVariant),
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              r['kind'] == 'add_back'
                                  ? Fmt.money(Fmt.toDouble(r['amount']))
                                  : '(${Fmt.money(
                                      Fmt.toDouble(r['amount']))})',
                              style: TextStyle(
                                color: r['kind'] == 'add_back'
                                    ? null
                                    : scheme.primary,
                              ),
                            ),
                            if (canPost)
                              IconButton(
                                icon: const Icon(Icons.close, size: 18),
                                tooltip: 'Remove',
                                onPressed: () => _remove(context, ref, r),
                              ),
                          ],
                        ),
                      ),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _AdjustmentDialog extends ConsumerStatefulWidget {
  const _AdjustmentDialog({required this.computationId});

  final String computationId;

  @override
  ConsumerState<_AdjustmentDialog> createState() =>
      _AdjustmentDialogState();
}

class _AdjustmentDialogState extends ConsumerState<_AdjustmentDialog> {
  final _label = TextEditingController();
  final _amount = TextEditingController();
  final _reason = TextEditingController();
  String _kind = 'add_back';

  @override
  void dispose() {
    _label.dispose();
    _amount.dispose();
    _reason.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final amount = double.tryParse(_amount.text.trim().replaceAll(',', ''));
    final problem = switch (null) {
      _ when _label.text.trim().isEmpty => 'Say what the adjustment is.',
      _ when amount == null || amount <= 0 => 'Enter an amount above zero.',
      _ => null,
    };
    if (problem != null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(problem)));
      return;
    }

    final done = await runWithFeedback(
      context,
      doing: 'add the adjustment',
      successMessage: 'Added',
      action: () => ref.read(repoProvider)!.addTaxAdjustment(
        computationId: widget.computationId,
        kind: _kind,
        label: _label.text.trim(),
        amount: amount!,
        reason: _reason.text.trim().isEmpty ? null : _reason.text.trim(),
      ),
    );
    if (done && mounted) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('An adjustment'),
    content: SizedBox(
      width: 460,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'add_back', label: Text('Add back')),
              ButtonSegment(value: 'deduct', label: Text('Deduct')),
            ],
            selected: {_kind},
            onSelectionChanged: (v) => setState(() => _kind = v.first),
          ),
          const SizedBox(height: Space.md),
          TextField(
            key: const ValueKey('adjustment-label'),
            controller: _label,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: 'What it is',
              hintText: 'Director\u2019s private mileage',
            ),
          ),
          const SizedBox(height: Space.md),
          TextField(
            key: const ValueKey('adjustment-amount'),
            controller: _amount,
            keyboardType:
                const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(
              labelText: 'How much',
              prefixText: 'RM ',
            ),
          ),
          const SizedBox(height: Space.md),
          TextField(
            key: const ValueKey('adjustment-reason'),
            controller: _reason,
            decoration: const InputDecoration(
              labelText: 'Why',
              hintText: 'Log book, 40% of motor expenses',
              helperText: 'The line a reviewer stops at is the one with '
                  'no reason beside it.',
              helperMaxLines: 2,
            ),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(onPressed: _save, child: const Text('Add')),
    ],
  );
}
