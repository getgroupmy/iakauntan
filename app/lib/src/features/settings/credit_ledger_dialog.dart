import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/skeletons.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';

/// Where the scanning credit went.
///
/// `credit_ledger` records every movement of the balance — what was
/// bought, what each scan took, what was refunded or adjusted — and
/// `creditLedgerProvider` reads it, watched by nothing. The settings
/// card showed a balance and a price per scan and could not answer the
/// only question anybody asks of a prepaid balance: what happened to
/// it. A company being charged per scan could see the number go down
/// and never what took it.

/// What kind of movement this is, in words.
///
/// The type says what happened and the sign says which way, which is
/// why an adjustment can be either — "the sign lives here and not in
/// the type", as the column's own comment puts it.
String creditMovement(String? entryType) => switch (entryType) {
  'topup' => 'Credit bought',
  'usage' => 'A scan',
  'refund' => 'Refunded',
  _ => 'Adjustment',
};

/// Whether this movement put credit in.
///
/// `amount` is signed and the check constraint refuses zero, so there
/// is no third answer.
bool creditWentIn(num amount) => amount > 0;

/// What went in and what went out, over what the ledger returned.
///
/// Stated separately rather than netted: a company that bought a
/// hundred ringgit and spent ninety is in a different position from one
/// that bought ten and spent nothing, and the balance alone cannot tell
/// them apart.
({double inTotal, double outTotal}) creditFlows(
  Iterable<Map<String, dynamic>> rows,
) {
  var inTotal = 0.0, outTotal = 0.0;
  for (final r in rows) {
    final amount = double.tryParse('${r['amount'] ?? 0}') ?? 0;
    if (creditWentIn(amount)) {
      inTotal += amount;
    } else {
      outTotal += -amount;
    }
  }
  return (
    inTotal: double.parse(inTotal.toStringAsFixed(2)),
    outTotal: double.parse(outTotal.toStringAsFixed(2)),
  );
}

/// Where the credit went.
Future<void> showCreditLedger(BuildContext context) =>
    showDialog<void>(context: context, builder: (_) => const _LedgerDialog());

class _LedgerDialog extends ConsumerWidget {
  const _LedgerDialog();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ledger = ref.watch(creditLedgerProvider);

    return AlertDialog(
      title: const Text('Where the credit went'),
      content: SizedBox(
        width: 540,
        height: 440,
        child: AsyncView<List<Map<String, dynamic>>>(
          value: ledger,
          onRetry: () => ref.invalidate(creditLedgerProvider),
          skeleton: const ListSkeleton(rows: 4, leading: false),
          builder: (rows) {
            if (rows.isEmpty) {
              return const EmptyState(
                icon: Icons.receipt_long_outlined,
                title: 'Nothing yet',
                message: 'No credit has been bought or spent.',
              );
            }
            final flows = creditFlows(rows);
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: ListView.separated(
                    itemCount: rows.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (_, i) {
                      final r = rows[i];
                      final amount =
                          double.tryParse('${r['amount'] ?? 0}') ?? 0;
                      final into = creditWentIn(amount);
                      return ListTile(
                        dense: true,
                        title: Text('${r['description']}'),
                        subtitle: Text(
                          '${creditMovement(r['entry_type'] as String?)} · '
                          '${Fmt.dateTime(DateTime.parse('${r['created_at']}').toLocal())}',
                          style: const TextStyle(fontSize: 12),
                        ),
                        trailing: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Text(
                              '${into ? '+' : ''}${Fmt.money(amount)}',
                              style: TextStyle(
                                fontWeight: FontWeight.w600,
                                color: into
                                    ? context.colors.success
                                    : context.scheme.onSurfaceVariant,
                              ),
                            ),
                            Text(
                              'left ${Fmt.money(num.tryParse('${r['balance_after'] ?? 0}'))}',
                              style: const TextStyle(fontSize: 11),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
                const Divider(height: 1),
                Padding(
                  padding: const EdgeInsets.only(top: Space.sm),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Over the last ${rows.length} movements',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                      Text(
                        '${Fmt.money(flows.inTotal)} in · '
                        '${Fmt.money(flows.outTotal)} out',
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }
}
