import 'package:flutter/material.dart';

import '../../core/format.dart';
import '../../core/theme.dart';
import '../../data/ocr_repository.dart';

/// What was read off a document, before anybody acts on it.
///
/// Shown rather than applied silently, because a machine reading a faded
/// thermal receipt is a good first draft and not a source document. The
/// figures are on screen next to the paper they came from, and it takes
/// a deliberate press to put them in the form.
///
/// Returns true when [canApply] and the reader accepted it.
Future<bool?> showScanResult(
  BuildContext context,
  OcrExtraction read, {
  bool canApply = false,
}) =>
    showDialog<bool>(
      context: context,
      builder: (_) => _ScanResultDialog(read: read, canApply: canApply),
    );

class _ScanResultDialog extends StatelessWidget {
  const _ScanResultDialog({required this.read, required this.canApply});

  final OcrExtraction read;
  final bool canApply;

  @override
  Widget build(BuildContext context) {
    final nothing = read.supplierName == null &&
        read.totalAmount == null &&
        read.documentNo == null;

    return AlertDialog(
      title: const Text('What the document says'),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (nothing)
                Text(
                  'Nothing legible came back. A sharper photograph of the '
                  'whole receipt, flat and in daylight, usually does it.',
                  style: Theme.of(context).textTheme.bodyMedium,
                )
              else ...[
                _Row('Supplier', read.supplierName),
                _Row('Tax number', read.supplierTaxId),
                _Row('Document no', read.documentNo),
                _Row('Date',
                    read.documentDate == null ? null : Fmt.date(read.documentDate)),
                _Row('Currency', read.currency),
                _Row('Subtotal',
                    read.subtotal == null ? null : Fmt.money(read.subtotal!)),
                _Row('Tax',
                    read.taxAmount == null ? null : Fmt.money(read.taxAmount!)),
                _Row('Total',
                    read.totalAmount == null
                        ? null
                        : Fmt.money(read.totalAmount!),
                    bold: true),
                if (read.lines.isNotEmpty) ...[
                  const Divider(height: Space.xl),
                  Text('Lines',
                      style: Theme.of(context).textTheme.labelLarge),
                  const SizedBox(height: 6),
                  for (final line in read.lines)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Row(children: [
                        Expanded(
                          child: Text(line.description ?? '—',
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 13)),
                        ),
                        if (line.amount != null)
                          Text(Fmt.money(line.amount!),
                              style: const TextStyle(fontSize: 13)),
                      ]),
                    ),
                ],
              ],
              // Anything the reader flagged as needing a human. Put last
              // and given its own box, because it is the one line here
              // that is a warning rather than a figure.
              if (read.note != null) ...[
                const SizedBox(height: Space.md),
                Container(
                  padding: const EdgeInsets.all(Space.md),
                  decoration: BoxDecoration(
                    color: context.colors.warning.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(read.note!,
                      style: const TextStyle(fontSize: 13)),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: Text(canApply ? 'Discard' : 'Close'),
        ),
        if (canApply && !nothing)
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Use these'),
          ),
      ],
    );
  }
}

class _Row extends StatelessWidget {
  const _Row(this.label, this.value, {this.bold = false});

  final String label;
  final String? value;
  final bool bold;

  @override
  Widget build(BuildContext context) {
    // A field the document does not carry is shown as absent rather than
    // hidden: "no tax number printed" is worth knowing when the reason
    // an e-Invoice will be rejected is that there is not one.
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(
          width: 110,
          child: Text(label, style: Theme.of(context).textTheme.bodySmall),
        ),
        Expanded(
          child: Text(
            value ?? 'Not on the document',
            style: TextStyle(
              fontWeight: bold ? FontWeight.w600 : FontWeight.w400,
              color: value == null ? context.scheme.onSurfaceVariant : null,
              fontStyle: value == null ? FontStyle.italic : null,
            ),
          ),
        ),
      ]),
    );
  }
}
