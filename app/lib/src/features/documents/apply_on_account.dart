import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/skeletons.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/models.dart';

/// Money already banked, set against a document raised later.
///
/// The receipts screen has told people for a long time that what is left
/// on a receipt "can be set against a future invoice", and nothing in
/// the app could do it: `allocate_with_discount` exists, and its only
/// caller created the receipt in the same breath. So an overpayment
/// went in, showed as on account, and stayed there.
///
/// `0464` made leaving it on account the sanctioned answer to somebody
/// paying too much, which turns a stale promise into a dead end. This is
/// the other half of that.
///
/// No journal is posted here and none is needed: the receipt credited
/// the receivable on the day it was banked. What this changes is which
/// invoice the money is against.
Future<bool> showApplyOnAccount(
  BuildContext context, {
  required String settlementId,
  required bool isSales,
  required String contactId,
  required double available,
  required String currency,
}) async {
  final done = await showDialog<bool>(
    context: context,
    builder: (_) => _ApplyOnAccount(
      settlementId: settlementId,
      isSales: isSales,
      contactId: contactId,
      available: available,
      currency: currency,
    ),
  );
  return done ?? false;
}

class _ApplyOnAccount extends ConsumerStatefulWidget {
  const _ApplyOnAccount({
    required this.settlementId,
    required this.isSales,
    required this.contactId,
    required this.available,
    required this.currency,
  });

  final String settlementId;
  final bool isSales;
  final String contactId;
  final double available;
  final String currency;

  @override
  ConsumerState<_ApplyOnAccount> createState() => _ApplyOnAccountState();
}

class _ApplyOnAccountState extends ConsumerState<_ApplyOnAccount> {
  final _amounts = <String, TextEditingController>{};
  final _selected = <String>{};
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    for (final c in _amounts.values) {
      c.dispose();
    }
    super.dispose();
  }

  double get _total {
    var sum = 0.0;
    for (final id in _selected) {
      sum += double.tryParse(_amounts[id]?.text ?? '') ?? 0;
    }
    return sum;
  }

  /// What is left of the money after what has been ticked. Shown rather
  /// than enforced silently: somebody spreading a payment over four
  /// invoices needs to see it run out.
  double get _left => widget.available - _total;

  Future<void> _apply(List<BusinessDocument> docs) async {
    final repo = ref.read(repoProvider);
    if (repo == null || _selected.isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      for (final d in docs) {
        if (!_selected.contains(d.id)) continue;
        final amount = double.tryParse(_amounts[d.id]?.text ?? '') ?? 0;
        if (amount <= 0) continue;
        if (widget.isSales) {
          await repo.allocateWithDiscount(
            receiptId: widget.settlementId,
            invoiceId: d.id,
            amount: amount,
          );
        } else {
          await repo.allocatePaymentWithDiscount(
            paymentId: widget.settlementId,
            billId: d.id,
            amount: amount,
          );
        }
      }
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      // The database refuses more than the document owes, more than the
      // receipt holds, and money belonging to another party. Its
      // messages say which, so they are shown rather than replaced.
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final kind = widget.isSales ? DocKind.sales : DocKind.purchase;
    final open = ref.watch(
      outstandingProvider((kind: kind, contactId: widget.contactId)),
    );

    return AlertDialog(
      title: Text(widget.isSales ? 'Set against an invoice' : 'Set against a bill'),
      content: SizedBox(
        width: 560,
        child: AsyncView(
          value: open,
          onRetry: () => ref.invalidate(outstandingProvider(
            (kind: kind, contactId: widget.contactId),
          )),
          // A row for each unpaid document with a box to put money in,
          // which is what the trailing bone stands for.
          skeleton: const CardRowsSkeleton(
            rows: 3,
            leading: false,
            trailing: 1,
            trailingWidth: 110,
          ),
          builder: (docs) {
            if (docs.isEmpty) {
              return EmptyState(
                icon: Icons.inbox_outlined,
                title: widget.isSales
                    ? 'Nothing outstanding'
                    : 'Nothing to settle',
                message: widget.isSales
                    ? 'This customer has no unpaid invoice for the money to '
                          'go against. It stays on account until they do.'
                    : 'This supplier has no unpaid bill for the money to go '
                          'against.',
              );
            }
            return SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    '${Fmt.money(widget.available, currency: widget.currency)} '
                    'on account',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const SizedBox(height: Space.sm),
                  for (final d in docs) _row(d),
                  const SizedBox(height: Space.sm),
                  Text(
                    _left < 0
                        ? '${Fmt.money(-_left, currency: widget.currency)} more '
                              'than there is on account'
                        : '${Fmt.money(_left, currency: widget.currency)} would '
                              'be left on account',
                    style: TextStyle(
                      color: _left < 0
                          ? context.colors.danger
                          : Theme.of(context).textTheme.bodySmall?.color,
                      fontSize: 12,
                    ),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: Space.sm),
                    Container(
                      padding: const EdgeInsets.all(Space.md),
                      decoration: BoxDecoration(
                        color: context.colors.danger.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        _error!,
                        style: TextStyle(color: context.colors.danger),
                      ),
                    ),
                  ],
                ],
              ),
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('apply-on-account'),
          onPressed: _selected.isEmpty || _busy || _left < 0
              ? null
              : () => _apply(open.valueOrNull ?? const []),
          child: const Text('Apply'),
        ),
      ],
    );
  }

  Widget _row(BusinessDocument d) {
    final isOn = _selected.contains(d.id);
    final controller = _amounts.putIfAbsent(
      d.id,
      () => TextEditingController(text: d.balanceAmount.toStringAsFixed(2)),
    );

    return Row(
      children: [
        Checkbox(
          value: isOn,
          onChanged: (v) => setState(() {
            if (v ?? false) {
              _selected.add(d.id);
            } else {
              _selected.remove(d.id);
            }
          }),
        ),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(d.docNo),
              Text(
                '${Fmt.money(d.balanceAmount, currency: d.currency)} open  ·  '
                '${Fmt.date(d.docDate)}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
        SizedBox(
          width: 110,
          child: TextField(
            controller: controller,
            enabled: isOn,
            textAlign: TextAlign.right,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
            ],
            decoration: const InputDecoration(
              isDense: true,
              border: OutlineInputBorder(),
            ),
            onChanged: (_) => setState(() {}),
          ),
        ),
      ],
    );
  }
}
