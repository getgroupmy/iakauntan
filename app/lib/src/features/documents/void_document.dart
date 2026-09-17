import 'package:flutter/material.dart';

import '../../core/theme.dart';

/// Undoing a document.
///
/// `void_sales_document` has been in the schema since the sales side
/// went in, and `deleteDocument` since before that, and neither had a
/// caller: an invoice raised in error — wrong customer, wrong month,
/// keyed twice — could not be taken back from the app at all, and a
/// draft typed by mistake could not be thrown away. The only remedy
/// was a manual journal against an invoice that stayed on the ledger
/// looking real.

/// Why this document cannot be voided, or null when it can be.
///
/// `void_sales_document` refuses two shapes and says why each time:
/// a document with a payment applied, and one whose e-Invoice LHDN has
/// accepted. Both are answers worth having before pressing a button
/// rather than after, so the reason is carried to the menu item and
/// shown there.
String? voidBlockedBecause({
  required String status,
  required num paidAmount,
  required String? einvoiceStatus,
}) {
  if (status == 'void') return 'This one is already void.';
  if (status == 'draft') {
    return 'A draft has never been posted. Discard it instead.';
  }
  if (paidAmount > 0) {
    // Reversing the invoice under a receipt would leave the receipt
    // pointing at nothing and the customer's balance wrong.
    return 'Money has been received against this. Undo the receipt first.';
  }
  if (einvoiceStatus == 'valid') {
    return 'LHDN has accepted the e-Invoice. Cancel it with them first.';
  }
  return null;
}

/// Whether this document can be thrown away rather than voided.
///
/// A draft has never reached the ledger, so there is nothing to
/// reverse and nothing an auditor needs to see. Anything posted is
/// voided instead, which leaves the document and its reversal both
/// standing.
bool canDiscard(String status) => status == 'draft';

/// Ask why, and mean it.
///
/// `void_sales_document` takes a null reason and writes "Voided: " with
/// nothing after it, which is a line somebody has to explain a year
/// later. The dialog will not return an empty one.
Future<String?> askVoidReason(
  BuildContext context, {
  required String docNo,
}) async {
  final controller = TextEditingController();
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text('Void $docNo'),
      content: SizedBox(
        width: 400,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'The posting is reversed and the document stays, marked '
              'void. It keeps its number, because a gap in a numbered '
              'run is the thing an auditor asks about.',
              style: Theme.of(ctx).textTheme.bodySmall,
            ),
            const SizedBox(height: Space.md),
            TextField(
              key: const ValueKey('void-reason'),
              controller: controller,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Why',
                hintText: 'Raised against the wrong customer',
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
          onPressed: () {
            final reason = controller.text.trim();
            if (reason.isNotEmpty) Navigator.of(ctx).pop(reason);
          },
          child: const Text('Void it'),
        ),
      ],
    ),
  );
}

/// Confirm throwing a draft away.
Future<bool> askDiscard(BuildContext context, {required String docNo}) async =>
    await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Discard $docNo?'),
        content: const Text(
          'It has never been posted, so nothing in the ledger changes. '
          'It stops appearing in the lists.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Keep it'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Discard'),
          ),
        ],
      ),
    ) ??
    false;
