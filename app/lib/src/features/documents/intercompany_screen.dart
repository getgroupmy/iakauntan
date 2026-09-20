import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/skeletons.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
// The group-level writes live in an extension on Repo.
import '../../data/repository.dart';

/// Invoices another company in the group has addressed to this one.
///
/// A separate screen rather than a filter on the bills list, because
/// these are not bills yet. Nothing has been entered in this company's
/// books: they are documents sitting in somebody else's system with
/// this company's name on them, and turning one into a bill is an act
/// somebody here performs.
///
/// What arrives is a draft. Two things cannot cross a company boundary
/// — which expense account a line belongs to, and which of this
/// company's items it is — so the bill opens in the editor for those to
/// be set, and posts the ordinary way.
class IntercompanyScreen extends ConsumerWidget {
  const IntercompanyScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final inbox = ref.watch(intercompanyInboxProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('From group companies')),
      body: AsyncView(
        value: inbox,
        onRetry: () => ref.invalidate(intercompanyInboxProvider),
        // Cards rather than rows: each one is an invoice from another
        // company in the group, with three lines and something to
        // press.
        skeleton: const CardRowsSkeleton(
          rows: 3,
          leading: false,
          lines: 3,
          trailing: 1,
          trailingWidth: 96,
          rowGap: Space.lg,
        ),
        builder: (rows) {
          if (rows.isEmpty) {
            return const EmptyState(
              icon: Icons.swap_horiz,
              title: 'Nothing from the group',
              message:
                  'An invoice appears here when another company in '
                  'the group posts one addressed to this company — that '
                  'is, to a customer whose record points at it.',
            );
          }

          return SingleChildScrollView(
            child: PageBody(
              maxWidth: 900,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final row in rows) _InvoiceCard(row: row),
                  const SizedBox(height: 40),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _InvoiceCard extends ConsumerStatefulWidget {
  const _InvoiceCard({required this.row});

  final Map<String, dynamic> row;

  @override
  ConsumerState<_InvoiceCard> createState() => _InvoiceCardState();
}

class _InvoiceCardState extends ConsumerState<_InvoiceCard> {
  bool _busy = false;

  Future<void> _accept() async {
    setState(() => _busy = true);
    String? billId;
    final ok = await runWithFeedback(
      context,
      action: () async {
        billId = await ref
            .read(repoProvider)!
            .acceptIntercompanyBill(widget.row['sales_document_id'].toString());
      },
      successMessage: null,
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok && billId != null) {
      ref.invalidate(intercompanyInboxProvider);
      // Straight into the draft, because it is not finished: the
      // accounts are still to be set and nothing has posted.
      context.go('/purchases/bill/$billId');
    }
  }

  @override
  Widget build(BuildContext context) {
    final row = widget.row;
    final billed = row['already_billed'] == true;
    final supplier = row['supplier_contact_id'];

    return Card(
      margin: const EdgeInsets.only(bottom: Space.md),
      child: Padding(
        padding: const EdgeInsets.all(Space.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    row['from_org']?.toString() ?? '',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                Text(
                  Fmt.money(Fmt.toDouble(row['total_amount'])),
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ],
            ),
            const SizedBox(height: 2),
            Text(
              '${row['doc_no']} · '
              '${Fmt.date(DateTime.parse(row['doc_date'].toString()))}'
              '${Fmt.toDouble(row['tax_amount']) == 0 ? '' : ' · tax '
                        '${Fmt.money(Fmt.toDouble(row['tax_amount']))}'}',
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: Space.md),
            if (billed)
              Row(
                children: [
                  Icon(
                    Icons.check_circle_outline,
                    size: 16,
                    color: context.colors.success,
                  ),
                  const SizedBox(width: Space.sm),
                  const Expanded(
                    child: Text(
                      'Already billed here',
                      style: TextStyle(fontSize: 12),
                    ),
                  ),
                  TextButton(
                    onPressed: () =>
                        context.go('/purchases/bill/${row['bill_id']}'),
                    child: const Text('Open the bill'),
                  ),
                ],
              )
            else if (supplier == null)
              // Named rather than a disabled button with no explanation.
              // A bill has to be owed to somebody on this company's own
              // books, and nobody here stands for that company yet.
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.info_outline,
                    size: 16,
                    color: context.colors.info,
                  ),
                  const SizedBox(width: Space.sm),
                  Expanded(
                    child: Text(
                      'Add a supplier in this company linked to '
                      '${row['from_org']} before raising a bill from it.',
                      style: TextStyle(
                        fontSize: 12,
                        color: context.colors.info,
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: () => context.go('/contacts/new?type=supplier'),
                    child: const Text('Add supplier'),
                  ),
                ],
              )
            else
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton.icon(
                  key: ValueKey('accept-${row['sales_document_id']}'),
                  onPressed: _busy ? null : _accept,
                  icon: const Icon(Icons.receipt_long_outlined, size: 18),
                  label: const Text('Raise a bill'),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
