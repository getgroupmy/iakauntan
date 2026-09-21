import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/skeletons.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/models.dart';
import 'tax_computation_screen.dart' show TaxLine, TaxSection;

/// Form P: a partnership, which is not a taxable person.
///
/// It pays nothing. It computes a divisible income and allocates it to
/// the partners, each of whom then files their own Form B — so the
/// output of this screen is a list of figures people carry away, and
/// there is deliberately no "tax payable" anywhere on it.
///
/// A salary to a partner is not an expense of the partnership: a
/// partner cannot employ themselves. It is added back and handed to
/// that partner, which is why the salaries are held here rather than
/// hunted for in the ledger.
class FormPScreen extends ConsumerWidget {
  const FormPScreen({super.key, required this.computationId});

  final String computationId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(title: const Text('Form P')),
      body: AsyncView(
        value: ref.watch(partnershipSummaryProvider(computationId)),
        onRetry: () =>
            ref.invalidate(partnershipSummaryProvider(computationId)),
        skeleton: const Padding(
          padding: EdgeInsets.all(Space.lg),
          child: CardRowsSkeleton(
            rows: 6,
            leading: false,
            lines: 1,
            trailing: 1,
            trailingWidth: 100,
          ),
        ),
        builder: (s) => _FormP(id: computationId, summary: s),
      ),
    );
  }
}

class _FormP extends ConsumerWidget {
  const _FormP({required this.id, required this.summary});

  final String id;
  final PartnershipSummary summary;

  Future<void> _editPartner(
    BuildContext context,
    WidgetRef ref, [
    Map<String, dynamic>? existing,
  ]) async {
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => _PartnerDialog(computationId: id, existing: existing),
    );
    if (saved != true) return;
    ref.invalidate(taxPartnersProvider(id));
    ref.invalidate(partnershipAllocationProvider(id));
    ref.invalidate(partnershipSummaryProvider(id));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final canPost = ref.watch(canPostProvider);

    return ListView(
      padding: const EdgeInsets.all(Space.lg),
      children: [
        PageBody(
          maxWidth: 900,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Said first and plainly. A Form P that produced a tax
              // figure would be wrong in the most expensive possible
              // direction, so the screen states the opposite before
              // anybody looks for one.
              Container(
                padding: const EdgeInsets.all(Space.md),
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(Radii.md),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.info_outline, size: 18, color: scheme.onSurface),
                    const SizedBox(width: Space.sm),
                    Expanded(
                      child: Text(
                        'A partnership pays no tax. It allocates its '
                        'income to the partners, and each of them puts '
                        'their share on their own Form B.',
                        style: TextStyle(
                          fontSize: 12,
                          color: scheme.onSurface,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: Space.lg),

              // A partnership whose ratios come to ninety allocates
              // nine tenths of its income and the missing tenth appears
              // nowhere — the allocation still adds up, down its own
              // column, to the wrong number.
              if (!summary.isEmpty && !summary.sharesBalance)
                _Warning(
                  key: const ValueKey('form-p-shares'),
                  text:
                      'The shares come to ${Fmt.qty(summary.sharesTotal)}%, '
                      'not 100%. Everything below is allocated in those '
                      'proportions, so the figures add up to the wrong '
                      'total rather than looking wrong.',
                ),

              const TaxSection(title: 'The partnership'),
              TaxLine('Adjusted income, per the accounts',
                  summary.adjustedIncome),
              if (summary.appropriations > 0)
                TaxLine(
                  'Partners’ salaries and interest, added back',
                  summary.appropriations,
                  hint: 'Not an expense — a partner cannot employ '
                      'themselves',
                ),
              const Divider(),
              TaxLine(
                'Adjusted income of the partnership',
                summary.partnershipAdjusted,
                bold: true,
              ),
              TaxLine(
                'Divisible income',
                summary.divisibleIncome,
                hint: 'What is left once the appropriations are handed '
                    'to the partners who earned them',
              ),

              const SizedBox(height: Space.lg),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'The partners',
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                  ),
                  if (canPost)
                    TextButton.icon(
                      key: const ValueKey('add-partner'),
                      onPressed: () => _editPartner(context, ref),
                      icon: const Icon(Icons.add, size: 18),
                      label: const Text('Add a partner'),
                    ),
                ],
              ),
              _Partners(id: id, onEdit: (row) => _editPartner(context, ref, row)),

              const SizedBox(height: Space.lg),
              Text(
                'Each partner carries their statutory income onto their '
                'own Form B. Nothing here is sent to LHDN.\n\n'
                'This assumes the accounts EXPENSED the partners’ '
                'salaries and interest, which is what a partnership’s '
                'books almost always do. Where they were shown below the '
                'line instead, these figures over-allocate by that '
                'amount.',
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

class _Partners extends ConsumerWidget {
  const _Partners({required this.id, required this.onEdit});

  final String id;
  final ValueChanged<Map<String, dynamic>> onEdit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final canPost = ref.watch(canPostProvider);
    final rows = ref.watch(taxPartnersProvider(id));

    return AsyncView(
      value: ref.watch(partnershipAllocationProvider(id)),
      onRetry: () => ref.invalidate(partnershipAllocationProvider(id)),
      skeleton: const CardRowsSkeleton(
        rows: 3,
        leadingSize: 32,
        trailing: 1,
        trailingWidth: 90,
      ),
      builder: (allocation) {
        if (allocation.isEmpty) {
          return const EmptyState(
            icon: Icons.groups_outlined,
            title: 'No partners yet',
            message:
                'Add each partner with their share of the profits. A '
                'salary or interest on capital belongs to that partner '
                'alone and is added back before the rest is divided.',
          );
        }
        final raw = rows.valueOrNull ?? const <Map<String, dynamic>>[];
        return Column(
          children: [
            for (final a in allocation)
              Card(
                margin: const EdgeInsets.only(bottom: Space.sm),
                child: InkWell(
                  onTap: canPost
                      ? () {
                          final row = raw
                              .where((r) => r['id'] == a.partnerId)
                              .firstOrNull;
                          if (row != null) onEdit(row);
                        }
                      : null,
                  child: Padding(
                    padding: const EdgeInsets.all(Space.md),
                    child: Column(
                      key: ValueKey('partner-${a.partnerId}'),
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment:
                                    CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    a.name,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  Text(
                                    a.taxReference == null
                                        ? '${Fmt.qty(a.sharePercent)}% share'
                                        : '${Fmt.qty(a.sharePercent)}% · '
                                              '${a.taxReference}',
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: scheme.onSurfaceVariant,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            Text(
                              Fmt.money(a.statutoryIncome),
                              style: const TextStyle(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: Space.sm),
                        // The working, per partner. A partner asked
                        // where their figure came from wants these four
                        // lines and not an explanation.
                        _Small('Share of divisible income',
                            a.shareOfDivisible),
                        if (a.salary > 0) _Small('Salary', a.salary),
                        if (a.interestOnCapital > 0)
                          _Small('Interest on capital', a.interestOnCapital),
                        if (a.capitalAllowances > 0)
                          _Small('Capital allowances',
                              -a.capitalAllowances),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _Small extends StatelessWidget {
  const _Small(this.label, this.value);

  final String label;
  final double value;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                fontSize: 12,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
          Text(
            value < 0 ? '(${Fmt.money(-value)})' : Fmt.money(value),
            style: TextStyle(
              fontSize: 12,
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _Warning extends StatelessWidget {
  const _Warning({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(bottom: Space.md),
      padding: const EdgeInsets.all(Space.md),
      decoration: BoxDecoration(
        color: scheme.errorContainer,
        borderRadius: BorderRadius.circular(Radii.md),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.error_outline, size: 18,
              color: scheme.onErrorContainer),
          const SizedBox(width: Space.sm),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: 12,
                color: scheme.onErrorContainer,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PartnerDialog extends ConsumerStatefulWidget {
  const _PartnerDialog({required this.computationId, this.existing});

  final String computationId;
  final Map<String, dynamic>? existing;

  @override
  ConsumerState<_PartnerDialog> createState() => _PartnerDialogState();
}

class _PartnerDialogState extends ConsumerState<_PartnerDialog> {
  late final _name = TextEditingController(
    text: widget.existing?['name']?.toString() ?? '',
  );
  late final _reference = TextEditingController(
    text: widget.existing?['tax_reference']?.toString() ?? '',
  );
  late final _share = TextEditingController(
    text: widget.existing == null
        ? ''
        : Fmt.qty(Fmt.toDouble(widget.existing!['share_percent'])),
  );
  late final _salary = TextEditingController(
    text: widget.existing == null
        ? ''
        : Fmt.toDouble(widget.existing!['salary']).toStringAsFixed(2),
  );
  late final _interest = TextEditingController(
    text: widget.existing == null
        ? ''
        : Fmt.toDouble(widget.existing!['interest_on_capital'])
              .toStringAsFixed(2),
  );

  @override
  void dispose() {
    for (final c in [_name, _reference, _share, _salary, _interest]) {
      c.dispose();
    }
    super.dispose();
  }

  double _num(TextEditingController c) =>
      double.tryParse(c.text.trim().replaceAll(',', '')) ?? 0;

  Future<void> _save() async {
    final share = _num(_share);
    final problem = switch (null) {
      _ when _name.text.trim().isEmpty => 'Name the partner.',
      _ when share < 0 || share > 100 =>
        'A share is between nothing and a hundred per cent.',
      _ => null,
    };
    if (problem != null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(problem)));
      return;
    }

    final done = await runWithFeedback(
      context,
      doing: 'save the partner',
      successMessage: 'Saved',
      action: () => ref.read(repoProvider)!.saveTaxPartner(
        computationId: widget.computationId,
        id: widget.existing?['id'] as String?,
        name: _name.text.trim(),
        taxReference:
            _reference.text.trim().isEmpty ? null : _reference.text.trim(),
        sharePercent: share,
        salary: _num(_salary),
        interestOnCapital: _num(_interest),
      ),
    );
    if (done && mounted) Navigator.pop(context, true);
  }

  Future<void> _remove() async {
    final id = widget.existing?['id'] as String?;
    if (id == null) return;
    final yes = await confirm(
      context,
      title: 'Remove ${_name.text.trim()}?',
      message: 'Their share is not reallocated — the remaining shares '
          'will no longer come to a hundred until you fix them.',
      confirmLabel: 'Remove',
      destructive: true,
    );
    if (!yes || !mounted) return;
    final done = await runWithFeedback(
      context,
      doing: 'remove the partner',
      successMessage: 'Removed',
      action: () => ref.read(repoProvider)!.removeTaxPartner(id),
    );
    if (done && mounted) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.existing == null ? 'A partner' : 'This partner'),
    content: SizedBox(
      width: 460,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              key: const ValueKey('partner-name'),
              controller: _name,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'Name'),
            ),
            const SizedBox(height: Space.md),
            TextField(
              key: const ValueKey('partner-reference'),
              controller: _reference,
              decoration: const InputDecoration(
                labelText: 'Tax reference',
                hintText: 'SG 1234567890',
              ),
            ),
            const SizedBox(height: Space.md),
            TextField(
              key: const ValueKey('partner-share'),
              controller: _share,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(
                labelText: 'Share of the profits',
                suffixText: '%',
                helperText: 'All the partners’ shares must come to a '
                    'hundred.',
              ),
            ),
            const SizedBox(height: Space.md),
            TextField(
              key: const ValueKey('partner-salary'),
              controller: _salary,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(
                labelText: 'Salary',
                prefixText: 'RM ',
                helperText: 'Not an expense of the partnership. Added '
                    'back, then handed to this partner.',
                helperMaxLines: 2,
              ),
            ),
            const SizedBox(height: Space.md),
            TextField(
              key: const ValueKey('partner-interest'),
              controller: _interest,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(
                labelText: 'Interest on capital',
                prefixText: 'RM ',
              ),
            ),
          ],
        ),
      ),
    ),
    actions: [
      if (widget.existing != null)
        TextButton(
          onPressed: _remove,
          child: const Text('Remove'),
        ),
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(onPressed: _save, child: const Text('Save')),
    ],
  );
}
