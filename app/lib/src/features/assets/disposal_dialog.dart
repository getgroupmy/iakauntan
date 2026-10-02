import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/picker_options.dart';
import '../../core/providers.dart';
import '../../core/searchable_picker.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/models.dart';
import '../banking/new_bank_account_dialog.dart';

/// Why a disposal cannot be saved yet.
///
/// Null when there is nothing wrong. Proceeds have to land somewhere
/// nameable: `dispose_fixed_asset` refuses proceeds with no account
/// since `0729`, because it used to debit account 1120 -- the heading
/// the real bank accounts hang beneath -- so the money moved no bank
/// balance and appeared on no reconciliation. A disposal for NOTHING
/// needs no account, which is why this asks about the amount and not
/// just the box.
String? disposalProblem({
  required double proceeds,
  required String? bankAccountId,
}) => proceeds > 0 && bankAccountId == null
    ? 'Say which account the proceeds were received into. Proceeds with '
          'no account named cannot be reconciled against any statement.'
    : null;

/// Sells or scraps an asset.
///
/// The gain or loss shown here is provisional in one specific way, and
/// the dialog says so: depreciation is brought up to the disposal date
/// first, so an asset last charged in December and sold in June has six
/// months of catching up to do before the result is known.
Future<bool?> showDisposalDialog(
  BuildContext context,
  WidgetRef ref, {
  required FixedAsset asset,
}) {
  return showDialog<bool>(
    context: context,
    builder: (_) => _DisposalDialog(asset: asset),
  );
}

class _DisposalDialog extends ConsumerStatefulWidget {
  const _DisposalDialog({required this.asset});

  final FixedAsset asset;

  @override
  ConsumerState<_DisposalDialog> createState() => _DisposalDialogState();
}

class _DisposalDialogState extends ConsumerState<_DisposalDialog> {
  final _proceeds = TextEditingController(text: '0');
  DateTime _on = DateTime.now();
  String? _bankAccountId;
  bool _working = false;

  @override
  void dispose() {
    _proceeds.dispose();
    super.dispose();
  }

  double get _proceedsValue => double.tryParse(_proceeds.text.trim()) ?? 0;

  @override
  Widget build(BuildContext context) {
    final a = widget.asset;
    final banks = ref.watch(bankAccountsProvider).value ?? const [];

    // Against the depreciation charged so far. The database will charge
    // any months still outstanding before it works out the real figure,
    // so this is a floor on the gain, not the answer.
    final provisional = _proceedsValue - a.netBookValue;

    return AlertDialog(
      title: Text('Dispose of ${a.assetNo}'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(a.name,
                  style: const TextStyle(fontWeight: FontWeight.w600)),
              Text(
                'Cost ${Fmt.money(a.cost)} · depreciated '
                '${Fmt.money(a.accumulatedDepreciation)} · net book value '
                '${Fmt.money(a.netBookValue)}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 14),
              Row(children: [
                Expanded(
                  child: InkWell(
                    onTap: () async {
                      final picked = await showDatePicker(
                        context: context,
                        initialDate: _on,
                        firstDate: a.acquisitionDate,
                        lastDate: DateTime(2100),
                      );
                      if (picked != null) setState(() => _on = picked);
                    },
                    child: InputDecorator(
                      decoration: const InputDecoration(
                        labelText: 'Disposal date',
                        suffixIcon: Icon(Icons.calendar_today, size: 18),
                      ),
                      child: Text(Fmt.date(_on)),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: _proceeds,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    onChanged: (_) => setState(() {}),
                    decoration: const InputDecoration(
                      labelText: 'Proceeds',
                      prefixText: 'RM ',
                      helperText: 'Nothing if it was scrapped',
                    ),
                  ),
                ),
              ]),
              const SizedBox(height: 12),
              SearchablePicker<String>(
                options: bankPickerOptions(banks),
                createLabel: 'Add bank account',
                // 0529 made this list writable for the first
                // time. Until then a company that opened a
                // second account had nowhere in the product to
                // say so.
                onCreate: (typed) =>
                    createBankAccountFromPicker(context, typed: typed),
                value: _bankAccountId,
                label: _proceedsValue > 0 ? 'Proceeds into *' : 'Proceeds into',
                helperText: _proceedsValue > 0
                    ? null
                    : 'Nothing was received, so there is nothing to bank',
                // `allowEmpty` only where it is honest. It used to be
                // true always, with the empty row labelled "Cash" and a
                // helper saying "Left blank, they go to cash" -- and
                // THEY DID NOT. `dispose_fixed_asset` fell back to
                // account 1120, the heading the real bank accounts hang
                // under: no bank balance moved and the proceeds showed
                // on no reconciliation. `0729` refuses that, so where
                // there are proceeds this box is required, and where
                // there are none it is irrelevant and says so.
                allowEmpty: _proceedsValue <= 0,
                emptyLabel: 'No proceeds',
                onChanged: (v) => setState(() => _bankAccountId = v),
              ),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: (provisional >= 0
                          ? context.colors.success
                          : context.colors.warning)
                      .withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      provisional >= 0
                          ? 'Gain of about ${Fmt.money(provisional)}'
                          : 'Loss of about ${Fmt.money(-provisional)}',
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    Text(
                      'Any depreciation still owing up to '
                      '${Fmt.date(_on)} is charged first, so the posted '
                      'figure may be smaller than this.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
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
          onPressed: _working || disposalProblem(
                    proceeds: _proceedsValue,
                    bankAccountId: _bankAccountId,
                  ) !=
                  null
              ? null
              : _dispose,
          child: _working
              ? const SizedBox(
                  height: 18,
                  width: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Dispose'),
        ),
      ],
    );
  }

  Future<void> _dispose() async {
    final ok = await confirm(
      context,
      title: 'Dispose of ${widget.asset.assetNo}?',
      message: 'This takes the asset off the books and posts the gain or '
          'loss. It cannot be undone from here — a mistake has to be '
          'reversed in the journals.',
      confirmLabel: 'Dispose',
      destructive: true,
    );
    if (!ok || !mounted) return;

    setState(() => _working = true);
    final done = await runWithFeedback(
      context,
      action: () => ref.read(repoProvider)!.disposeFixedAsset(
            assetId: widget.asset.id,
            on: _on,
            proceeds: _proceedsValue,
            bankAccountId: _bankAccountId,
          ),
      successMessage: 'Asset disposed of',
      pendingMessage: 'Posting…',
    );

    if (mounted) setState(() => _working = false);
    if (done && mounted) Navigator.pop(context, true);
  }
}
