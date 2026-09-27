import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/skeletons.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/models.dart';
import 'tax_computation_screen.dart' show showTaxInputs, TaxLine, TaxSection;

/// Form B: a person with business income.
///
/// The business is ONE source. Employment, rent and a share of a
/// partnership join it at aggregate income, approved donations come off
/// there, personal reliefs come off after that, and the resident
/// individual scale applies.
///
/// That scale is PCB's — `0025` built it for the monthly estimate and
/// `0666` reads the same table, so the estimate and the return it
/// estimates cannot disagree.
class FormBScreen extends ConsumerWidget {
  const FormBScreen({super.key, required this.computationId});

  final String computationId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Form B'),
        actions: [
          IconButton(
            key: const ValueKey('form-b-inputs'),
            tooltip: 'Figures the accounts cannot know',
            icon: const Icon(Icons.tune),
            onPressed: () => showTaxInputs(context, computationId),
          ),
        ],
      ),
      body: AsyncView(
        value: ref.watch(individualTaxProvider(computationId)),
        onRetry: () => ref.invalidate(individualTaxProvider(computationId)),
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
        builder: (c) => _FormB(id: computationId, c: c),
      ),
    );
  }
}

class _FormB extends ConsumerWidget {
  const _FormB({required this.id, required this.c});

  final String id;
  final IndividualTaxComputation c;

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

              const TaxSection(title: 'Business source'),
              TaxLine('Profit before taxation', c.profitBeforeTax),
              if (c.addBacks != 0)
                TaxLine('Non-deductible expenses', c.addBacks),
              if (c.balancingCharge > 0)
                TaxLine('Balancing charge', c.balancingCharge),
              if (c.deductions > 0)
                TaxLine('Non-taxable income', -c.deductions),
              if (c.hasLoss)
                TaxLine('Adjusted loss', c.adjustedLoss, warn: true)
              else
                TaxLine('Adjusted income', c.adjustedIncome),
              TaxLine('Capital allowances', -c.caUsed),
              if (c.caCarriedForward > 0)
                TaxLine(
                  'Unabsorbed, carried forward',
                  c.caCarriedForward,
                  hint: 'Unabsorbed allowance — not a loss',
                ),
              TaxLine(
                'Statutory income from business',
                c.statutoryBusiness,
                bold: true,
              ),

              const TaxSection(
                title: 'Other sources',
                hint: 'Income this company’s books do not hold',
              ),
              _OtherIncome(id: id),
              TaxLine('Total other income', c.otherIncome),

              const Divider(),
              TaxLine('Aggregate income', c.aggregateIncome, bold: true),

              if (c.approvedDonations > 0) ...[
                const TaxSection(title: 'Approved donations'),
                TaxLine('Allowed', -c.donationsAllowed),
                // The claimed figure and the allowed one differing is
                // the sort of thing nobody expects, so it is said
                // rather than left as a smaller number.
                if (c.donationsRestricted)
                  TaxLine(
                    'Restricted',
                    c.approvedDonations - c.donationsAllowed,
                    hint: 's.44(6) cannot take the income below nothing '
                        '— the excess is lost, not carried forward',
                    warn: true,
                  ),
              ],

              const Divider(),
              TaxLine('Total income', c.totalIncome, bold: true),

              const TaxSection(title: 'Personal reliefs'),
              _Reliefs(id: id, on: c.periodTo),
              TaxLine('Total reliefs', -c.reliefsClaimed),

              const Divider(),
              TaxLine('Chargeable income', c.chargeableIncome, bold: true),

              const TaxSection(
                title: 'Tax',
                hint: 'At the resident individual scale — the same one '
                    'PCB uses',
              ),
              TaxLine('Tax charged', c.taxCharged),
              if (c.rebate > 0)
                TaxLine(
                  'Rebate',
                  -c.rebate,
                  hint: 'For a chargeable income under the threshold',
                ),
              if (c.zakatRebate > 0)
                TaxLine('Zakat rebate', -c.zakatRebate),
              if (c.s110TaxDeducted > 0)
                TaxLine('Tax deducted at source (s.110)', -c.s110TaxDeducted),
              if (c.instalmentsPaid > 0)
                TaxLine('Instalments paid (CP500)', -c.instalmentsPaid),

              const Divider(),
              TaxLine(
                c.isRefund ? 'Tax refundable' : 'Tax payable',
                c.isRefund ? -c.taxPayable : c.taxPayable,
                bold: true,
                warn: !c.isRefund && c.taxPayable > 0,
              ),

              const SizedBox(height: Space.lg),
              Text(
                'A working, not a filing. Nothing here is sent to LHDN. '
                'The reliefs offered are the ones payroll knows about; a '
                'Form B can carry others, and those are typed.',
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

/// Employment, rent, a share of a partnership.
class _OtherIncome extends ConsumerWidget {
  const _OtherIncome({required this.id});

  final String id;

  static const kinds = <String, String>{
    'employment': 'Employment',
    'rental': 'Rent',
    'interest': 'Interest',
    'dividend': 'Dividend',
    'partnership': 'Share of a partnership',
    'royalty': 'Royalty',
    'pension': 'Pension',
    'other': 'Other',
  };

  Future<void> _add(BuildContext context, WidgetRef ref) async {
    final made = await showDialog<bool>(
      context: context,
      builder: (_) => _OtherIncomeDialog(computationId: id),
    );
    if (made != true) return;
    ref.invalidate(taxOtherIncomeProvider(id));
    ref.invalidate(individualTaxProvider(id));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final canPost = ref.watch(canPostProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AsyncView(
          value: ref.watch(taxOtherIncomeProvider(id)),
          onRetry: () => ref.invalidate(taxOtherIncomeProvider(id)),
          skeleton: const CardRowsSkeleton(
            rows: 2,
            leading: false,
            trailing: 1,
            trailingWidth: 90,
          ),
          builder: (rows) => Column(
            children: [
              for (final r in rows)
                _RemovableLine(
                  key: ValueKey('other-income-${r['id']}'),
                  label: (r['label']?.toString().trim().isNotEmpty ?? false)
                      ? r['label'].toString()
                      : (kinds[r['kind']] ?? 'Other'),
                  hint: kinds[r['kind']] ?? 'Other',
                  amount: Fmt.toDouble(r['amount']),
                  onRemove: canPost
                      ? () async {
                          await ref
                              .read(repoProvider)!
                              .removeTaxOtherIncome(r['id'] as String);
                          ref.invalidate(taxOtherIncomeProvider(id));
                          ref.invalidate(individualTaxProvider(id));
                        }
                      : null,
                ),
            ],
          ),
        ),
        if (canPost)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              key: const ValueKey('add-other-income'),
              onPressed: () => _add(context, ref),
              icon: const Icon(Icons.add, size: 18),
              label: const Text('Add a source'),
            ),
          ),
      ],
    );
  }
}

/// What the person claims.
class _Reliefs extends ConsumerWidget {
  const _Reliefs({required this.id, required this.on});

  final String id;
  final DateTime? on;

  Future<void> _add(BuildContext context, WidgetRef ref) async {
    final made = await showDialog<bool>(
      context: context,
      builder: (_) => _ReliefDialog(
        computationId: id,
        on: on ?? DateTime.now(),
      ),
    );
    if (made != true) return;
    ref.invalidate(taxReliefClaimsProvider(id));
    ref.invalidate(individualTaxProvider(id));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final canPost = ref.watch(canPostProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AsyncView(
          value: ref.watch(taxReliefClaimsProvider(id)),
          onRetry: () => ref.invalidate(taxReliefClaimsProvider(id)),
          skeleton: const CardRowsSkeleton(
            rows: 3,
            leading: false,
            trailing: 1,
            trailingWidth: 90,
          ),
          builder: (rows) => Column(
            children: [
              for (final r in rows)
                _RemovableLine(
                  key: ValueKey('relief-${r['id']}'),
                  label: r['label']?.toString() ?? '',
                  hint: r['relief_code']?.toString(),
                  amount: Fmt.toDouble(r['amount']),
                  onRemove: canPost
                      ? () async {
                          await ref
                              .read(repoProvider)!
                              .removeTaxReliefClaim(r['id'] as String);
                          ref.invalidate(taxReliefClaimsProvider(id));
                          ref.invalidate(individualTaxProvider(id));
                        }
                      : null,
                ),
            ],
          ),
        ),
        if (canPost)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              key: const ValueKey('add-relief'),
              onPressed: () => _add(context, ref),
              icon: const Icon(Icons.add, size: 18),
              label: const Text('Claim a relief'),
            ),
          ),
      ],
    );
  }
}

class _RemovableLine extends StatelessWidget {
  const _RemovableLine({
    super.key,
    required this.label,
    required this.amount,
    this.hint,
    this.onRemove,
  });

  final String label;
  final String? hint;
  final double amount;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label),
                if (hint != null && hint != label)
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
          Text(Fmt.money(amount)),
          if (onRemove != null)
            IconButton(
              icon: const Icon(Icons.close, size: 16),
              tooltip: 'Remove',
              visualDensity: VisualDensity.compact,
              onPressed: onRemove,
            )
          else
            const SizedBox(width: Space.lg),
        ],
      ),
    );
  }
}

class _OtherIncomeDialog extends ConsumerStatefulWidget {
  const _OtherIncomeDialog({required this.computationId});

  final String computationId;

  @override
  ConsumerState<_OtherIncomeDialog> createState() =>
      _OtherIncomeDialogState();
}

class _OtherIncomeDialogState extends ConsumerState<_OtherIncomeDialog> {
  final _label = TextEditingController();
  final _amount = TextEditingController();
  String _kind = 'employment';

  @override
  void dispose() {
    _label.dispose();
    _amount.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final amount = double.tryParse(_amount.text.trim().replaceAll(',', ''));
    if (amount == null || amount < 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter an amount.')),
      );
      return;
    }
    final done = await runWithFeedback(
      context,
      doing: 'add the source',
      successMessage: 'Added',
      action: () => ref.read(repoProvider)!.addTaxOtherIncome(
        computationId: widget.computationId,
        kind: _kind,
        label: _label.text.trim().isEmpty ? null : _label.text.trim(),
        amount: amount,
      ),
    );
    if (done && mounted) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Another source of income'),
    content: SizedBox(
      width: 440,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DropdownButtonFormField<String>(
            key: const ValueKey('other-income-kind'),
            initialValue: _kind,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Kind'),
            items: [
              for (final e in _OtherIncome.kinds.entries)
                DropdownMenuItem(value: e.key, child: Text(e.value)),
            ],
            onChanged: (v) => setState(() => _kind = v ?? _kind),
          ),
          const SizedBox(height: Space.md),
          TextField(
            key: const ValueKey('other-income-label'),
            controller: _label,
            decoration: const InputDecoration(
              labelText: 'Which one, if it matters',
              hintText: 'Shoplot in Ipoh',
            ),
          ),
          const SizedBox(height: Space.md),
          TextField(
            key: const ValueKey('other-income-amount'),
            controller: _amount,
            autofocus: true,
            keyboardType:
                const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(
              labelText: 'For the basis period',
              prefixText: 'RM ',
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

/// Claiming a relief.
///
/// The catalogue is PCB's, which does not carry every relief a Form B
/// can. So a claim can be one of the listed ones or typed — and the
/// AMOUNT is always entered either way, because copying a cap in as the
/// claim is how somebody claims relief they did not incur.
class _ReliefDialog extends ConsumerStatefulWidget {
  const _ReliefDialog({required this.computationId, required this.on});

  final String computationId;
  final DateTime on;

  @override
  ConsumerState<_ReliefDialog> createState() => _ReliefDialogState();
}

class _ReliefDialogState extends ConsumerState<_ReliefDialog> {
  final _label = TextEditingController();
  final _amount = TextEditingController();
  String? _code;

  @override
  void dispose() {
    _label.dispose();
    _amount.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final amount = double.tryParse(_amount.text.trim().replaceAll(',', ''));
    final label = _label.text.trim();
    if (label.isEmpty || amount == null || amount < 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Name the relief and enter an amount.')),
      );
      return;
    }
    final done = await runWithFeedback(
      context,
      doing: 'claim the relief',
      successMessage: 'Claimed',
      action: () => ref.read(repoProvider)!.addTaxReliefClaim(
        computationId: widget.computationId,
        reliefCode: _code,
        label: label,
        amount: amount,
      ),
    );
    if (done && mounted) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final catalogue = ref.watch(individualReliefsProvider(widget.on));

    return AlertDialog(
      title: const Text('Claim a relief'),
      content: SizedBox(
        width: 460,
        child: AsyncView(
          value: catalogue,
          onRetry: () =>
              ref.invalidate(individualReliefsProvider(widget.on)),
          skeleton: const FormSkeleton(fields: 3),
          builder: (list) {
            final chosen =
                list.where((r) => r['code'] == _code).firstOrNull;
            final cap = chosen?['max_amount'];

            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                DropdownButtonFormField<String?>(
                  key: const ValueKey('relief-code'),
                  initialValue: _code,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Which'),
                  items: [
                    const DropdownMenuItem(
                      value: null,
                      child: Text('Something else (type it)'),
                    ),
                    for (final r in list)
                      DropdownMenuItem(
                        value: r['code'] as String,
                        child: Text(r['name']?.toString() ?? ''),
                      ),
                  ],
                  onChanged: (v) => setState(() {
                    _code = v;
                    final picked =
                        list.where((r) => r['code'] == v).firstOrNull;
                    if (picked != null) {
                      _label.text = picked['name']?.toString() ?? '';
                    }
                  }),
                ),
                const SizedBox(height: Space.md),
                TextField(
                  key: const ValueKey('relief-label'),
                  controller: _label,
                  decoration: const InputDecoration(labelText: 'Called'),
                ),
                const SizedBox(height: Space.md),
                TextField(
                  key: const ValueKey('relief-amount'),
                  controller: _amount,
                  autofocus: true,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  decoration: InputDecoration(
                    labelText: 'Claimed',
                    prefixText: 'RM ',
                    // The cap is SHOWN and not filled in. Filling it in
                    // is how somebody claims RM8,000 of medical
                    // expenses they did not incur.
                    helperText: cap == null
                        ? null
                        : 'At most ${Fmt.money(Fmt.toDouble(cap))} — '
                              'enter what was actually incurred.',
                    helperMaxLines: 2,
                  ),
                ),
                const SizedBox(height: Space.sm),
                Text(
                  'These are the reliefs payroll knows about. A Form B '
                  'can carry others — pick "Something else" and type it.',
                  style: TextStyle(
                    fontSize: 11,
                    color: scheme.onSurfaceVariant,
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
        FilledButton(onPressed: _save, child: const Text('Claim')),
      ],
    );
  }
}
