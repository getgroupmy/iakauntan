import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/skeletons.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';

/// What the company has bought and not put in the register.
///
/// `fixed_assets.purchase_document_id` has been a column since `0084`
/// and nothing wrote it, so the register and the fixed asset accounts in
/// the ledger were two records of the same money with no way to be
/// compared. A bill line coded to Plant and equipment put 12,500 in
/// 1510; somebody typed 12,000 into the register; depreciation ran on
/// the smaller figure for five years and the auditor found it.
///
/// This is that reconciliation from the ledger's end, and the way in to
/// fixing it: capitalising takes the cost, the date, the supplier and
/// the account from the line rather than asking for them again.
Future<void> showUncapitalisedPurchases(BuildContext context) {
  return showDialog<void>(
    context: context,
    builder: (_) => const _UncapitalisedDialog(),
  );
}

class _UncapitalisedDialog extends ConsumerWidget {
  const _UncapitalisedDialog();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rows = ref.watch(uncapitalisedPurchasesProvider);

    return AlertDialog(
      title: const Text('Bought, not in the register'),
      content: SizedBox(
        width: 640,
        child: SingleChildScrollView(
          child: AsyncView(
            value: rows,
            onRetry: () => ref.invalidate(uncapitalisedPurchasesProvider),
            skeleton: const ListSkeleton(rows: 3, leading: false),
            builder: (list) => list.isEmpty
                ? const Padding(
                    padding: EdgeInsets.symmetric(vertical: Space.lg),
                    child: Text('Every posted bill line coded to a fixed '
                        'asset account has an asset against it. The '
                        'register and the ledger agree.'),
                  )
                : Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        'These lines put money in a fixed asset account '
                        'and nothing in the register is claiming it. '
                        'Until they are capitalised the two do not '
                        'reconcile.',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      const SizedBox(height: Space.md),
                      for (final r in list)
                        ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          title: Text(
                            r['description']?.toString().isNotEmpty == true
                                ? r['description'].toString()
                                : r['doc_no'].toString(),
                          ),
                          subtitle: Text(
                            [
                              r['doc_no'],
                              Fmt.date(DateTime.tryParse(
                                  r['doc_date']?.toString() ?? '')),
                              r['supplier_name'],
                              '${r['account_code']} ${r['account_name']}',
                            ].map((e) => e?.toString() ?? '').join(' · '),
                            style: const TextStyle(fontSize: 12),
                          ),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                Fmt.money(Fmt.toDouble(r['amount'])),
                                style: const TextStyle(
                                    fontWeight: FontWeight.w600),
                              ),
                              const SizedBox(width: Space.sm),
                              FilledButton.tonal(
                                onPressed: () => _capitalise(context, ref, r),
                                child: const Text('Capitalise'),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
          ),
        ),
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Done'),
        ),
      ],
    );
  }

  Future<void> _capitalise(
      BuildContext context, WidgetRef ref, Map<String, dynamic> row) async {
    final done = await showDialog<bool>(
      context: context,
      builder: (_) => _CapitaliseDialog(row: row),
    );
    if (done == true) {
      ref.invalidate(uncapitalisedPurchasesProvider);
      ref.invalidate(fixedAssetsProvider);
    }
  }
}

/// The few things the bill line does not already know: what to call the
/// asset in the register, and how it is written down.
class _CapitaliseDialog extends ConsumerStatefulWidget {
  const _CapitaliseDialog({required this.row});

  final Map<String, dynamic> row;

  @override
  ConsumerState<_CapitaliseDialog> createState() => _CapitaliseDialogState();
}

class _CapitaliseDialogState extends ConsumerState<_CapitaliseDialog> {
  final _assetNo = TextEditingController();
  final _name = TextEditingController();
  final _category = TextEditingController();
  final _life = TextEditingController(text: '60');
  final _rate = TextEditingController();
  final _residual = TextEditingController(text: '0');
  String _method = 'straight_line';
  bool _saving = false;

  double get _cost => Fmt.toDouble(widget.row['amount']);

  @override
  void initState() {
    super.initState();
    _name.text = widget.row['description']?.toString() ?? '';
  }

  @override
  void dispose() {
    for (final c in [_assetNo, _name, _category, _life, _rate, _residual]) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Capitalise'),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Said rather than asked. The cost, the date, the supplier
              // and the account are the line's, which is what makes the
              // register and the ledger agree by construction instead of
              // because two people chose the same thing twice.
              Container(
                padding: const EdgeInsets.all(Space.md),
                decoration: BoxDecoration(
                  color: context.scheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  'Cost ${Fmt.money(_cost)} from '
                  '${widget.row['doc_no']}, dated '
                  '${Fmt.date(DateTime.tryParse(
                      widget.row['doc_date']?.toString() ?? ''))}, '
                  'in ${widget.row['account_code']} '
                  '${widget.row['account_name']}. Taken from the bill, '
                  'not typed.',
                  style: const TextStyle(fontSize: 12),
                ),
              ),
              const SizedBox(height: Space.md),
              TextField(
                controller: _assetNo,
                autofocus: true,
                decoration: const InputDecoration(labelText: 'Asset no *'),
              ),
              const SizedBox(height: Space.md),
              TextField(
                controller: _name,
                decoration: const InputDecoration(labelText: 'Name'),
              ),
              const SizedBox(height: Space.md),
              TextField(
                controller: _category,
                decoration: const InputDecoration(labelText: 'Category'),
              ),
              const SizedBox(height: Space.md),
              SegmentedButton<String>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(
                      value: 'straight_line', label: Text('Straight line')),
                  ButtonSegment(
                      value: 'reducing_balance', label: Text('Reducing')),
                ],
                selected: {_method},
                onSelectionChanged: (s) => setState(() => _method = s.first),
              ),
              const SizedBox(height: Space.md),
              if (_method == 'straight_line')
                TextField(
                  controller: _life,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'Useful life (months) *',
                  ),
                )
              else
                TextField(
                  controller: _rate,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(
                    labelText: 'Annual rate (%) *',
                  ),
                ),
              const SizedBox(height: Space.md),
              TextField(
                controller: _residual,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(
                  labelText: 'Residual value',
                  helperText: 'Never depreciated below this. Must be under '
                      '${Fmt.money(_cost)}.',
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: _saving
              ? const SizedBox(
                  height: 18,
                  width: 18,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('Capitalise'),
        ),
      ],
    );
  }

  Future<void> _save() async {
    final life = int.tryParse(_life.text.trim());
    final rate = double.tryParse(_rate.text.trim());
    final residual = double.tryParse(_residual.text.trim()) ?? 0;

    if (_assetNo.text.trim().isEmpty) {
      _say('Give it an asset number.');
      return;
    }
    // The table refuses a straight-line asset with no life and a
    // reducing-balance one with no rate; catching it here means the
    // answer arrives beside the empty box rather than as an error.
    if (_method == 'straight_line' && (life == null || life <= 0)) {
      _say('Say how many months it will last.');
      return;
    }
    if (_method == 'reducing_balance' && (rate == null || rate <= 0)) {
      _say('Say what rate it is written down at.');
      return;
    }
    if (residual > _cost) {
      _say('A residual above ${Fmt.money(_cost)} is more than it cost.');
      return;
    }

    setState(() => _saving = true);
    final ok = await runWithFeedback(
      context,
      action: () => ref.read(repoProvider)!.capitaliseBillLine(
            widget.row['line_id'] as String,
            assetNo: _assetNo.text.trim(),
            name: _name.text.trim().isEmpty ? null : _name.text.trim(),
            category:
                _category.text.trim().isEmpty ? null : _category.text.trim(),
            method: _method,
            usefulLifeMonths: _method == 'straight_line' ? life : null,
            ratePercent: _method == 'reducing_balance' ? rate : null,
            residualValue: residual,
          ),
      successMessage: 'In the register, at the figure the ledger holds.',
    );

    if (mounted) setState(() => _saving = false);
    if (ok && mounted) Navigator.pop(context, true);
  }

  void _say(String message) => ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(message)));
}
