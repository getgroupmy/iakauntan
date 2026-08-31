import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import 'deal_outcome.dart';

/// What the reasons were collected for.
///
/// Without this the reasons are another field somebody fills in, and a
/// field with no reader is the failure `0373` exists to fix rather than
/// half of it. The board answers "how much is in the pipeline"; this
/// answers "and why does it keep leaving".
Future<void> showWinLoss(BuildContext context) => showDialog<void>(
      context: context,
      builder: (_) => const _WinLossDialog(),
    );

class _WinLossDialog extends ConsumerStatefulWidget {
  const _WinLossDialog();

  @override
  ConsumerState<_WinLossDialog> createState() => _WinLossDialogState();
}

class _WinLossDialogState extends ConsumerState<_WinLossDialog> {
  // The last twelve months. A quarter is too short to see a pattern in
  // reasons, and a full year carries the seasonality most Malaysian
  // businesses have.
  late final DateTime _to = DateTime.now();
  late final DateTime _from = DateTime(_to.year - 1, _to.month, _to.day);

  late final Future<List<Map<String, dynamic>>> _rows = _load();

  Future<List<Map<String, dynamic>>> _load() =>
      ref.read(repoProvider)!.winLoss(from: _from, to: _to);

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Why deals closed'),
      content: SizedBox(
        width: 620,
        child: FutureBuilder<List<Map<String, dynamic>>>(
          future: _rows,
          builder: (context, snap) {
            if (snap.hasError) {
              return Text('${snap.error}');
            }
            if (!snap.hasData) {
              return const SizedBox(
                height: 120,
                child: Center(child: CircularProgressIndicator()),
              );
            }
            final rows = snap.data!;
            if (rows.isEmpty) {
              return const EmptyState(
                icon: Icons.query_stats_outlined,
                title: 'Nothing closed in the last year',
                message: 'Close a deal on the board and the reason lands here.',
              );
            }

            final total = rows.fold<double>(
                0, (a, r) => a + Fmt.toDouble(r['amount']));

            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '${Fmt.date(_from)} to ${Fmt.date(_to)} · '
                  '${Fmt.money(total)} closed',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: Space.sm),
                Flexible(
                  child: SingleChildScrollView(
                    child: Column(
                      children: [
                        for (final r in rows) _Row(row: r, total: total),
                      ],
                    ),
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

class _Row extends StatelessWidget {
  const _Row({required this.row, required this.total});

  final Map<String, dynamic> row;
  final double total;

  @override
  Widget build(BuildContext context) {
    final outcome = row['outcome']?.toString() ?? '';
    final amount = Fmt.toDouble(row['amount']);
    final competitors = row['competitors']?.toString();

    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: Chip(
        label: Text(dealOutcomes[outcome] ?? outcome),
        visualDensity: VisualDensity.compact,
      ),
      title: Text(row['reason']?.toString() ?? '—'),
      subtitle: competitors == null || competitors.isEmpty
          ? null
          // Named rather than counted: "three competitors" tells nobody
          // who to go and look at.
          : Text('vs $competitors', style: const TextStyle(fontSize: 11)),
      trailing: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Money(amount, bold: true),
          Text(
            '${row['deals']} deal${row['deals'] == 1 ? '' : 's'}'
            '${total == 0 ? '' : ' · ${(amount / total * 100).round()}%'}',
            style: const TextStyle(fontSize: 11),
          ),
        ],
      ),
    );
  }
}
