import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/skeletons.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';

/// What was moved between the company's own accounts.
///
/// `0101` records a transfer, posts it, and adjusts both balances, and
/// `bankTransfersProvider` has been in the app reading the register --
/// watched by nothing. The only reference to it anywhere was an
/// `invalidate` in the dialog that creates one, so a transfer, once
/// made, left the app entirely: not listed, not printable, and not
/// voidable, because `voidBankTransfer` had no caller either. A
/// transfer keyed to the wrong account could only be undone by a
/// manual journal.

/// Whether a transfer can still be undone.
///
/// `void_bank_transfer` refuses one that is already void, and refuses
/// nothing else: money moved between two accounts of the same company
/// has no customer who might have paid against it, so there is no
/// later state that makes it un-undoable.
bool transferIsVoidable(String? status) => status != 'void';

/// Where the money went.
String transferRoute(Map<String, dynamic> t) {
  final from = (t['from_account'] as Map?)?['name'] ?? '—';
  final to = (t['to_account'] as Map?)?['name'] ?? '—';
  return '$from → $to';
}

/// The currency an end of the transfer is in.
///
/// Each amount is in the money of the account it touches, so the two
/// ends of a cross-border transfer are in different currencies and a
/// single prefix on both would misstate one of them. MYR where the
/// account did not come back with one, which is what the column
/// defaults to.
String transferCurrency(Map<String, dynamic> t, String end) =>
    ((t['${end}_account'] as Map?)?['currency'] as String?) ?? 'MYR';

/// What left, what arrived, and what the bank took.
///
/// Stated separately whenever they differ, because they differ for two
/// quite different reasons — a charge, or a rate — and a single figure
/// hides both. The fee follows the sending account, so it is in that
/// account's money.
String transferAmounts(Map<String, dynamic> t) {
  final sent = num.tryParse('${t['amount_sent'] ?? 0}') ?? 0;
  final received = num.tryParse('${t['amount_received'] ?? 0}') ?? 0;
  final charges = num.tryParse('${t['bank_charges'] ?? 0}') ?? 0;
  final from = transferCurrency(t, 'from');
  final to = transferCurrency(t, 'to');

  final parts = <String>[Fmt.money(sent, currency: from)];
  if (received != sent || to != from) {
    parts.add('${Fmt.money(received, currency: to)} arrived');
  }
  if (charges > 0) {
    parts.add('${Fmt.money(charges, currency: from)} charges');
  }
  return parts.join(' · ');
}

/// The register of transfers, and the way to undo one.
Future<bool> showTransfersHistory(BuildContext context) async =>
    await showDialog<bool>(
      context: context,
      builder: (_) => const _TransfersDialog(),
    ) ??
    false;

class _TransfersDialog extends ConsumerStatefulWidget {
  const _TransfersDialog();

  @override
  ConsumerState<_TransfersDialog> createState() => _TransfersDialogState();
}

class _TransfersDialogState extends ConsumerState<_TransfersDialog> {
  bool _changed = false;

  Future<void> _void(Map<String, dynamic> t) async {
    final controller = TextEditingController();
    final reason = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Void ${t['transfer_no']}'),
        content: SizedBox(
          width: 380,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'The posting is reversed and both balances go back to '
                'where they were. The transfer stays on the list, marked '
                'void, because it happened.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: Space.md),
              TextField(
                key: const ValueKey('void-transfer-reason'),
                controller: controller,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: 'Why',
                  hintText: 'Keyed to the wrong account',
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Keep it'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text.trim()),
            child: const Text('Void it'),
          ),
        ],
      ),
    );
    if (reason == null || !mounted) return;

    final ok = await runWithFeedback(
      context,
      action: () => ref.read(repoProvider)!.voidBankTransfer(
            '${t['id']}',
            reason,
          ),
      successMessage: 'Voided and reversed',
    );
    if (ok && mounted) {
      _changed = true;
      ref.invalidate(bankTransfersProvider);
      ref.invalidate(bankAccountsProvider);
    }
  }

  @override
  Widget build(BuildContext context) {
    final transfers = ref.watch(bankTransfersProvider);
    final canPost = ref.watch(canPostProvider);

    return AlertDialog(
      title: const Text('Transfers between accounts'),
      content: SizedBox(
        width: 560,
        height: 440,
        child: AsyncView<List<Map<String, dynamic>>>(
          value: transfers,
          onRetry: () => ref.invalidate(bankTransfersProvider),
          skeleton: const ListSkeleton(rows: 4, leading: false),
          builder: (rows) {
            if (rows.isEmpty) {
              return const EmptyState(
                icon: Icons.swap_horiz,
                title: 'Nothing moved yet',
                message: 'Money moved between the company’s own accounts '
                    'is listed here, with both ends of it.',
              );
            }
            return ListView.separated(
              itemCount: rows.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (_, i) {
                final t = rows[i];
                final voidable = transferIsVoidable('${t['status']}');
                return ListTile(
                  dense: true,
                  title: Text(
                    '${t['transfer_no']} · ${transferRoute(t)}',
                    style: TextStyle(
                      decoration: voidable ? null : TextDecoration.lineThrough,
                    ),
                  ),
                  subtitle: Text(
                    '${Fmt.date(DateTime.tryParse('${t['transfer_date']}'))} · '
                    '${transferAmounts(t)}',
                    style: const TextStyle(fontSize: 12),
                  ),
                  trailing: !canPost || !voidable
                      ? StatusChip('${t['status']}', compact: true)
                      : TextButton(
                          onPressed: () => _void(t),
                          child: const Text('Void'),
                        ),
                );
              },
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(_changed),
          child: const Text('Close'),
        ),
      ],
    );
  }
}
