import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/safe_link.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/ocr_repository.dart';
import '../../data/platform_catalog_repository.dart';
import 'subscription_summary.dart';
import 'ways_to_pay.dart';

/// What this company is paying iAkauntan, and how to settle it.
///
/// 0488 let an owner switch a paid add-on on; 0489 raises the invoice
/// for it on the first of the following month. Two gaps sat either side
/// of that, and this card is both of them:
///
///   * between switching a module on and the invoice arriving, a price
///     had been agreed to with nothing to look at. That is the running
///     total at the top -- what is on, and what it has cost so far.
///
///   * `platform_invoices` was listed in exactly one place: inside the
///     *scanning* card, and only when the key source was 'platform'. It
///     was written in 0111 for scanning credit, which is what lived in
///     that table then. A company using its own OCR key, or doing OCR
///     on device, could not see its subscription invoice at all, let
///     alone pay it -- and the bill has nothing to do with scanning.
///     The list moved here, Pay button and all.
///
/// Drawn only for an owner or admin. The server refuses everybody else,
/// and a card that renders an error for a clerk who did nothing wrong is
/// worse than a card that is not there.
class SubscriptionCard extends ConsumerStatefulWidget {
  const SubscriptionCard({super.key, required this.canAdmin});

  final bool canAdmin;

  @override
  ConsumerState<SubscriptionCard> createState() => _SubscriptionCardState();
}

class _SubscriptionCardState extends ConsumerState<SubscriptionCard> {
  String? _busyId;

  /// Ask for a hosted checkout and go there.
  ///
  /// Nothing here decides whether an invoice may be paid. The button is
  /// drawn for an outstanding one and hidden otherwise, which is a
  /// convenience and not a control: `billplz-checkout` reads the invoice
  /// under the caller's own token and 0297 decides the rest.
  Future<void> _pay(Map<String, dynamic> invoice) async {
    final id = '${invoice['id']}';
    final repo = ref.read(repoProvider);
    if (repo == null) return;
    setState(() => _busyId = id);
    try {
      final opened = await launchExternal(await repo.startInvoiceCheckout(id));
      if (!mounted) return;
      if (!opened) {
        // The bill exists at the gateway whether or not the browser
        // cooperated, so "something went wrong" would be wrong: the
        // address is real and going there again works.
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Could not open the payment page. Try again.'),
          ),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    } finally {
      // Both guarded: somebody who taps Pay and navigates away disposes
      // this widget while the call is still in flight, and `ref` after
      // dispose throws -- inside a `finally`, where it would replace
      // whatever was actually being handled.
      if (mounted) {
        setState(() => _busyId = null);
        ref.invalidate(creditInvoicesProvider);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.canAdmin) return const SizedBox.shrink();

    final charges = ref.watch(moduleChargesProvider);
    final invoices = ref.watch(creditInvoicesProvider);
    final text = Theme.of(context).textTheme;

    // Not knowing yet counts as no: a Pay that appears a second later is
    // better than one that was never going to work.
    final gateways =
        ref
            .watch(
              gatewaysForCountryProvider(
                ref.watch(currentOrgProvider).valueOrNull?.countryCode,
              ),
            )
            .valueOrNull ??
        const <Map<String, dynamic>>[];
    final canPayOnline = hostedCheckout(gateways) != null;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Space.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SectionHeader(
              'Your subscription',
              subtitle:
                  'What the add-ons on this company cost, and the '
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
                    style: text.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(subscriptionRunningLine(month), style: text.bodySmall),
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
              onRetry: () => ref.invalidate(creditInvoicesProvider),
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
                // Three different situations and three different
                // sentences, because the action each calls for is
                // different: wait, read the instructions, or ask.
                final byHand = owed > 0 ? payByHandBecause(gateways) : null;
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (owed > 0)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          '${Fmt.money(owed)} outstanding',
                          key: const ValueKey('subscription-outstanding'),
                          style: text.bodyMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    if (byHand != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(byHand, style: text.bodySmall),
                      ),
                    for (final i in rows.take(12))
                      ListTile(
                        key: ValueKey('platform-invoice-${i['id']}'),
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                        title: Text(
                          '${i['invoice_no']} · '
                          '${Fmt.money(Fmt.toDouble(i['total_amount']))}',
                        ),
                        // What the invoice is actually for. The same
                        // table carries scanning credit top-ups, and
                        // "Document scanning credit" beside "Modules for
                        // January 2026" is the only thing that tells
                        // them apart.
                        subtitle: Text(
                          '${i['description']}'.split('\n').first,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: subscriptionInvoiceOwing(i) && canPayOnline
                            ? FilledButton.tonal(
                                key: ValueKey('pay-invoice-${i['id']}'),
                                onPressed: _busyId == null
                                    ? () => _pay(i)
                                    : null,
                                child: _busyId == '${i['id']}'
                                    ? const SizedBox(
                                        width: 14,
                                        height: 14,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                        ),
                                      )
                                    : const Text('Pay'),
                              )
                            : StatusChip(
                                subscriptionInvoiceStatus(i),
                                compact: true,
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
