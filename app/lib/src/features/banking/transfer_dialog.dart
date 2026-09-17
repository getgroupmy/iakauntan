import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/searchable_picker.dart';
import '../../core/widgets.dart';

/// Moving money between the company's own accounts.
///
/// Three amounts rather than one, because which of them the bank took
/// its fee from varies by bank and the database checks that they
/// reconcile. Across currencies it will not guess what arrived — that
/// would be inventing a rate — so the received field stops being
/// optional.
Future<bool?> showTransferDialog(BuildContext context) {
  return showDialog<bool>(
    context: context,
    builder: (_) => const _TransferDialog(),
  );
}

class _TransferDialog extends ConsumerStatefulWidget {
  const _TransferDialog();

  @override
  ConsumerState<_TransferDialog> createState() => _TransferDialogState();
}

class _TransferDialogState extends ConsumerState<_TransferDialog> {
  final _sent = TextEditingController();
  final _received = TextEditingController();
  final _charges = TextEditingController(text: '0');
  final _reference = TextEditingController();

  String? _from;
  String? _to;
  DateTime _date = DateTime.now();
  bool _saving = false;

  @override
  void dispose() {
    for (final c in [_sent, _received, _charges, _reference]) {
      c.dispose();
    }
    super.dispose();
  }

  String _currencyOf(List<Map<String, dynamic>> accounts, String? id) =>
      accounts.firstWhere((a) => a['id'] == id,
          orElse: () => const {'currency': 'MYR'})['currency']?.toString() ??
      'MYR';

  Future<void> _save(List<Map<String, dynamic>> accounts) async {
    final sent = double.tryParse(_sent.text.trim()) ?? 0;
    final charges = double.tryParse(_charges.text.trim()) ?? 0;
    final typed = double.tryParse(_received.text.trim());

    setState(() => _saving = true);
    final ok = await runWithFeedback(
      context,
      action: () => ref.read(repoProvider)!.transferBetweenBanks(
            fromAccountId: _from!,
            toAccountId: _to!,
            amountSent: sent,
            date: _date,
            // Left to the database when both ends share a currency and
            // nobody typed one: it works out what arrived and refuses
            // the sum if it does not come to what left.
            amountReceived: typed,
            bankCharges: charges,
            reference:
                _reference.text.trim().isEmpty ? null : _reference.text.trim(),
          ),
      successMessage: 'Transferred',
    );
    if (!mounted) return;
    setState(() => _saving = false);
    if (ok) {
      ref.invalidate(bankTransfersProvider);
      ref.invalidate(bankAccountsProvider);
      refreshLedgerData(ref);
      Navigator.of(context).pop(true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final accounts = ref.watch(bankAccountsProvider);

    return AlertDialog(
      title: const Text('Transfer between accounts'),
      content: SizedBox(
        width: 520,
        child: AsyncView(
          value: accounts,
          onRetry: () => ref.invalidate(bankAccountsProvider),
          builder: (list) {
            if (list.length < 2) {
              return const EmptyState(
                icon: Icons.account_balance_outlined,
                title: 'Only one account',
                message: 'A transfer needs somewhere to come from and '
                    'somewhere to go. Add a second bank account first.',
              );
            }

            final cross = _from != null &&
                _to != null &&
                _currencyOf(list, _from) != _currencyOf(list, _to);

            return SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SearchablePicker<String>(
                    options: [
                      for (final a in list)
                        PickerOption<String>(
                          value: a['id'] as String,
                          label: '${a['name']}',
                          // The CURRENCY, because a transfer between
                          // two currencies is a different piece of
                          // arithmetic and the person choosing needs to
                          // see which they picked.
                          sublabel: '${a['currency']}',
                          keywords: ['${a['currency']}'],
                        ),
                    ],
                    value: _from,
                    label: 'Out of',
                    onChanged: (v) => setState(() => _from = v),
                  ),
                  const SizedBox(height: 12),
                  SearchablePicker<String>(
                    options: [
                      for (final a in list)
                        // An account cannot pay itself, so it is not
                        // offered rather than refused after the fact.
                        if (a['id'] != _from)
                          PickerOption<String>(
                            value: a['id'] as String,
                            label: '${a['name']}',
                            sublabel: '${a['currency']}',
                            keywords: ['${a['currency']}'],
                          ),
                    ],
                    value: _to,
                    label: 'Into',
                    onChanged: (v) => setState(() => _to = v),
                  ),
                  const SizedBox(height: 16),
                  Row(children: [
                    Expanded(
                      child: TextField(
                        controller: _sent,
                        keyboardType: const TextInputType.numberWithOptions(
                            decimal: true),
                        onChanged: (_) => setState(() {}),
                        decoration: InputDecoration(
                          labelText: 'Left the account',
                          prefixText: '${_currencyOf(list, _from)} ',
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    SizedBox(
                      width: 150,
                      child: TextField(
                        controller: _charges,
                        keyboardType: const TextInputType.numberWithOptions(
                            decimal: true),
                        decoration: const InputDecoration(labelText: 'Of it, fees'),
                      ),
                    ),
                  ]),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _received,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    decoration: InputDecoration(
                      labelText: 'Arrived',
                      prefixText: '${_currencyOf(list, _to)} ',
                      helperText: cross
                          ? 'Required: the two accounts are in different '
                              'currencies, and the shortfall is exchange'
                          : 'Leave empty for what left, less the fees',
                    ),
                  ),
                  const SizedBox(height: 12),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('On'),
                    trailing: TextButton(
                      onPressed: () async {
                        final picked = await showDatePicker(
                          context: context,
                          initialDate: _date,
                          firstDate: DateTime(2000),
                          lastDate: DateTime(2100),
                        );
                        if (picked != null) setState(() => _date = picked);
                      },
                      child: Text(Fmt.date(_date)),
                    ),
                  ),
                  TextField(
                    controller: _reference,
                    decoration: const InputDecoration(
                      labelText: 'Reference',
                      hintText: 'The bank’s transaction number',
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _saving ||
                  _from == null ||
                  _to == null ||
                  (double.tryParse(_sent.text.trim()) ?? 0) <= 0
              ? null
              : () => _save(accounts.valueOrNull ?? const []),
          child: const Text('Transfer'),
        ),
      ],
    );
  }
}
