import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/skeletons.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';

/// Fixed-fee files that have gone past what the client was quoted.
///
/// `matters.agreed_fee` has been a column since `0021` and nothing read
/// it, so a firm that over-billed an agreed fee found out when the
/// client said so — which is finding out from the wrong person.
///
/// It counts unbilled time as well as invoices, because the question is
/// what the client will be asked for and not what they have been asked
/// for. Time already on a bill is in the billed figure, so it is not
/// counted twice.
Future<void> showMattersOverAgreedFee(BuildContext context) {
  return showDialog<void>(
    context: context,
    builder: (_) => const _OverAgreedFeeDialog(),
  );
}

class _OverAgreedFeeDialog extends ConsumerWidget {
  const _OverAgreedFeeDialog();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rows = ref.watch(mattersOverAgreedFeeProvider);

    return AlertDialog(
      title: const Text('Over the agreed fee'),
      content: SizedBox(
        width: 600,
        child: SingleChildScrollView(
          child: AsyncView(
            value: rows,
            onRetry: () => ref.invalidate(mattersOverAgreedFeeProvider),
            skeleton: const ListSkeleton(rows: 3, leading: false),
            builder: (list) => list.isEmpty
                ? const Padding(
                    padding: EdgeInsets.symmetric(vertical: Space.lg),
                    child: Text('No fixed-fee matter has gone past what was '
                        'quoted. Files with no agreed fee are not counted: '
                        'there is nothing to be over.'),
                  )
                : Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        'Billed plus time still to bill, against what the '
                        'client was quoted. Not a refusal — fees do get '
                        'renegotiated — but somebody should be the one to '
                        'raise it.',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      const SizedBox(height: Space.md),
                      for (final r in list)
                        ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          title: Text('${r['matter_no']} · '
                              '${r['matter_name']}'),
                          subtitle: Text(
                            '${r['client_name']} · agreed '
                            '${Fmt.money(Fmt.toDouble(r['agreed_fee']))} · '
                            'billed ${Fmt.money(Fmt.toDouble(r['billed']))}'
                            '${Fmt.toDouble(r['unbilled']) == 0 ? '' : ' · '
                                '${Fmt.money(Fmt.toDouble(r['unbilled']))} '
                                'still to bill'}',
                            style: const TextStyle(fontSize: 12),
                          ),
                          trailing: Text(
                            '+${Fmt.money(Fmt.toDouble(r['over_by']))}',
                            style: TextStyle(
                              fontWeight: FontWeight.w700,
                              color: context.colors.warning,
                            ),
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
}
