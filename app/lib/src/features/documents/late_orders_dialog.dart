import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';

/// Which orders are past the day we promised them.
///
/// `sales_documents.delivery_date` was a column since `0005` that
/// nothing wrote and nothing read. Carrying it forward through the
/// transfer chain would have been half the job: a date nobody looks at
/// is the same failure in a different place, and this is the half that
/// makes it worth recording.
Future<void> showLateOrders(BuildContext context) => showDialog<void>(
      context: context,
      builder: (_) => const _LateOrdersDialog(),
    );

class _LateOrdersDialog extends ConsumerStatefulWidget {
  const _LateOrdersDialog();

  @override
  ConsumerState<_LateOrdersDialog> createState() => _LateOrdersDialogState();
}

class _LateOrdersDialogState extends ConsumerState<_LateOrdersDialog> {
  late final Future<List<Map<String, dynamic>>> _rows =
      ref.read(repoProvider)!.lateOrders();

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Past the date we promised'),
      content: SizedBox(
        width: 640,
        child: FutureBuilder<List<Map<String, dynamic>>>(
          future: _rows,
          builder: (context, snap) {
            if (snap.hasError) return Text('${snap.error}');
            if (!snap.hasData) {
              return const SizedBox(
                height: 120,
                child: Center(child: CircularProgressIndicator()),
              );
            }
            final rows = snap.data!;
            if (rows.isEmpty) {
              return const EmptyState(
                icon: Icons.local_shipping_outlined,
                title: 'Nothing is late',
                message: 'Orders with a promised delivery date that has '
                    'passed, and something still unshipped, appear here.',
              );
            }
            return Flexible(
              child: SingleChildScrollView(
                child: Column(
                  children: [
                    for (final r in rows)
                      ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        onTap: () {
                          Navigator.of(context).pop();
                          context.go(
                              '/sales/sales_order/${r['document_id']}');
                        },
                        title: Text(
                          '${r['doc_no']} · ${r['contact_name'] ?? '—'}',
                        ),
                        subtitle: Text(
                          'Promised ${Fmt.date(Fmt.parseDate(r['delivery_date']))}'
                          ' · ${Fmt.qty(Fmt.toDouble(r['outstanding']))} of '
                          '${Fmt.qty(Fmt.toDouble(r['ordered']))} still to go',
                          style: const TextStyle(fontSize: 11),
                        ),
                        trailing: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Text(
                              '${r['days_late']} days late',
                              style: TextStyle(
                                fontWeight: FontWeight.w600,
                                color: context.colors.danger,
                              ),
                            ),
                            Money(Fmt.toDouble(r['amount'])),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
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
