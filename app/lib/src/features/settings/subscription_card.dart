import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import 'subscription_summary.dart';

/// What this company is paying iAkauntan.
///
/// 0488 let an owner switch a paid add-on on; 0489 raises the invoice
/// for it on the first of the following month. Between those two dates
/// there was nothing to look at — a price agreed to and no way to see
/// it — and afterwards the invoice existed in `platform_invoices` with
/// no screen that read it. Both halves are here.
///
/// Drawn only for an owner or admin. The server refuses everybody else,
/// and a card that renders an error for a clerk who did nothing wrong is
/// worse than a card that is not there.
class SubscriptionCard extends ConsumerWidget {
  const SubscriptionCard({super.key, required this.canAdmin});

  final bool canAdmin;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!canAdmin) return const SizedBox.shrink();

    final charges = ref.watch(moduleChargesProvider);
    final invoices = ref.watch(myPlatformInvoicesProvider);
    final text = Theme.of(context).textTheme;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Space.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SectionHeader(
              'Your subscription',
              subtitle: 'What the add-ons on this company cost, and the '
                  'invoices raised for them.',
            ),
            AsyncView(
              value: charges,
              onRetry: () => ref.invalidate(moduleChargesProvider),
              loading: const LinearProgressIndicator(),
              builder: (month) => Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    subscriptionRunningTotal(month),
                    key: const ValueKey('subscription-running-total'),
                    style: text.headlineSmall
                        ?.copyWith(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    subscriptionRunningLine(month),
                    style: text.bodySmall,
                  ),
                  for (final c in month.lines)
                    Padding(
                      key: ValueKey('charge-${c.code}'),
                      padding: const EdgeInsets.only(top: 8),
                      child: Row(
                        children: [
                          Expanded(child: Text(subscriptionChargeLine(c))),
                          Text(Fmt.money(c.amount)),
                        ],
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            const Divider(),
            const SizedBox(height: 8),
            Text(
              'Invoices',
              style: text.titleSmall?.copyWith(fontWeight: FontWeight.w600),
            ),
            AsyncView(
              value: invoices,
              onRetry: () => ref.invalidate(myPlatformInvoicesProvider),
              loading: const LinearProgressIndicator(),
              builder: (rows) {
                if (rows.isEmpty) {
                  return Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      'None yet. The first one is raised on the first of '
                      'the month after you add something.',
                      style: text.bodySmall,
                    ),
                  );
                }
                final owed = subscriptionOutstanding(rows);
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (owed > 0)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          '${Fmt.money(owed)} outstanding',
                          key: const ValueKey('subscription-outstanding'),
                          style: text.bodyMedium
                              ?.copyWith(fontWeight: FontWeight.w600),
                        ),
                      ),
                    for (final i in rows)
                      ListTile(
                        key: ValueKey('platform-invoice-${i['id']}'),
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                        title: Text(i['invoice_no'] as String? ?? ''),
                        subtitle: Text(
                          Fmt.date(DateTime.tryParse(
                              i['issue_date'] as String? ?? '')),
                        ),
                        trailing: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Text(Fmt.money(i['total_amount'] as num?)),
                            Text(
                              subscriptionInvoiceStatus(i),
                              style: text.bodySmall,
                            ),
                          ],
                        ),
                      ),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}
