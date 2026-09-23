import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../data/ocr_repository.dart';
import 'scan_destination.dart';

/// What is this, then?
///
/// Asked when nothing could say: the reader placed no target on it, the
/// classifier matched no kind, or — the case that has its own sentence —
/// the page was read and turned out not to be what the person expected.
///
/// A sheet of named destinations rather than a picker of document kinds
/// on purpose. The kinds table is the platform's vocabulary and it is
/// long; this is the question a person can actually answer while
/// holding the paper, and each option says what will happen next rather
/// than what the document is called.
Future<ScanDestination?> showScanKindSheet(
  BuildContext context, {
  OcrExtraction? read,

  /// Why this is being asked, where there is a reason worth giving.
  /// `0686`: "nothing on this names a supplier" is a finding, and a
  /// question asked without it reads as the app having lost its place.
  String? because,
}) {
  final named = read?.supplierName?.trim();
  return showModalBottomSheet<ScanDestination>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (sheetContext) => SafeArea(
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            Space.lg,
            0,
            Space.lg,
            Space.lg,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'What is this?',
                style: Theme.of(sheetContext).textTheme.titleLarge,
              ),
              const SizedBox(height: Space.sm),
              Text(
                because ??
                    'The reading could not place this document, so nothing '
                        'has been created. Choosing here is what decides '
                        'where it goes.',
                style: Theme.of(sheetContext).textTheme.bodySmall,
              ),
              // What the paper did say, where it said anything. Somebody
              // choosing blind is somebody guessing, and the name and
              // the total are usually enough to decide.
              if (named != null && named.isNotEmpty) ...[
                const SizedBox(height: Space.sm),
                Text(
                  'It names $named.',
                  style: Theme.of(sheetContext).textTheme.bodySmall,
                ),
              ],
              const SizedBox(height: Space.md),
              for (final d in offerableDestinations)
                ListTile(
                  key: ValueKey('scan-kind-${d.name}'),
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(_iconFor(d)),
                  title: Text(d.label),
                  onTap: () => Navigator.of(sheetContext).pop(d),
                ),
            ],
          ),
        ),
      ),
    ),
  );
}

IconData _iconFor(ScanDestination d) => switch (d) {
      ScanDestination.bill => Icons.receipt_long_outlined,
      ScanDestination.purchaseOrder => Icons.shopping_bag_outlined,
      ScanDestination.goodsReceived => Icons.local_shipping_outlined,
      ScanDestination.invoice => Icons.request_quote_outlined,
      ScanDestination.expense => Icons.receipt_outlined,
      ScanDestination.contact => Icons.badge_outlined,
      ScanDestination.bankStatement => Icons.account_balance_outlined,
      ScanDestination.unknown => Icons.help_outline,
    };
