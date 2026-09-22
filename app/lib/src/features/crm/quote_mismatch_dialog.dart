import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/row_actions.dart';
import '../../core/skeletons.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';

/// Open deals whose figure no longer matches the quotation attached to
/// them.
///
/// `opportunities.amount` is typed early and usually round — sixty
/// thousand, because that is the size of the job. The quotation that
/// goes out weeks later says 48,250, because by then somebody has
/// priced it. Both figures then sit in the system: the forecast comes
/// off one and the invoice off the other, and until `0384` nothing
/// compared them.
///
/// A revised quote is ordinary. Being unable to see which deals it has
/// happened to is not.
Future<void> showPipelineQuoteMismatch(BuildContext context) {
  return showDialog<void>(
    context: context,
    builder: (_) => const _QuoteMismatchDialog(),
  );
}

class _QuoteMismatchDialog extends ConsumerWidget {
  const _QuoteMismatchDialog();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rows = ref.watch(pipelineQuoteMismatchProvider);

    return AlertDialog(
      title: const Text('The forecast and the quotations'),
      content: SizedBox(
        width: 620,
        child: SingleChildScrollView(
          child: AsyncView(
            value: rows,
            onRetry: () => ref.invalidate(pipelineQuoteMismatchProvider),
            skeleton: const ListSkeleton(rows: 3, leading: false),
            builder: (list) => list.isEmpty
                ? const Padding(
                    padding: EdgeInsets.symmetric(vertical: Space.lg),
                    child: Text('Every open deal with a quotation agrees '
                        'with it. Deals with no quotation are not counted: '
                        'there is nothing to compare them to.'),
                  )
                : Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        'The forecast is running on the left-hand figure '
                        'and the customer was quoted the right-hand one.',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      const SizedBox(height: Space.md),
                      for (final r in list)
                        _MismatchTile(row: r),
                      const Divider(height: Space.xl),
                      Row(children: [
                        const Expanded(
                            child: Text('The pipeline is out by')),
                        Text(
                          Fmt.money(list.fold<double>(
                              0, (t, r) => t + Fmt.toDouble(r['difference']))),
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                      ]),
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

class _MismatchTile extends ConsumerWidget {
  const _MismatchTile({required this.row});

  final Map<String, dynamic> row;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final difference = Fmt.toDouble(row['difference']);
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      title: Text('${row['opportunity_no']} · ${row['deal_name']}'),
      subtitle: Text(
        '${row['contact_name'] ?? '—'} · deal '
        '${Fmt.money(Fmt.toDouble(row['deal_amount']))} · '
        '${row['doc_no']} ${Fmt.money(Fmt.toDouble(row['quoted_amount']))}',
        style: const TextStyle(fontSize: 12),
      ),
      // `RowActions`, not a bare Row. A figure plus a labelled button
      // is more than a `ListTile` has left on a phone, and this one
      // did not merely look tight -- it tripped Flutter's own
      // assertion, "Trailing widget consumes the entire tile width".
      // Below 700 the button becomes a menu and the figure stays put.
      trailing: RowActions(
        menuKey: 'mismatch-menu-${row['opportunity_id']}',
        leading: Padding(
          padding: const EdgeInsets.only(right: Space.sm),
          child: Text(
            '${difference >= 0 ? '+' : ''}${Fmt.money(difference)}',
            style: TextStyle(
              fontWeight: FontWeight.w700,
              // Over is not better than under: both mean the forecast
              // is reporting a number nobody quoted.
              color: context.colors.warning,
            ),
          ),
        ),
        actions: [
          // The document is the priced answer. Taking the deal to it
          // is the fix, and it is one tap.
          RowAction(
            label: 'Use quoted',
            actionKey: 'use-quoted-${row['opportunity_id']}',
            onTap: () => _adopt(context, ref),
          ),
        ],
      ),
    );
  }

  Future<void> _adopt(BuildContext context, WidgetRef ref) async {
    final ok = await runWithFeedback(
      context,
      action: () => ref.read(repoProvider)!.linkOpportunityQuotation(
            row['opportunity_id'] as String,
            row['doc_no'] == null ? null : row['document_id'] as String?,
          ),
      successMessage: 'The deal now says what was quoted.',
    );
    if (ok) {
      ref.invalidate(pipelineQuoteMismatchProvider);
      ref.invalidate(opportunitiesProvider);
    }
  }
}
