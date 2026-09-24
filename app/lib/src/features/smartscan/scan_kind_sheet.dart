import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../data/ocr_repository.dart';
import 'scan_destination.dart';

/// What somebody answered when asked what a document is.
///
/// Either a destination off the list, or a NAME they typed because
/// nothing on the list fitted — never both, and neither when the sheet
/// was dismissed.
typedef ScanKindAnswer = ({ScanDestination? to, String? named});

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
Future<ScanKindAnswer?> showScanKindSheet(
  BuildContext context, {
  OcrExtraction? read,

  /// Opens the page itself. `0709`.
  ///
  /// Asked for in the report this sheet came back from: "a popup where
  /// use can view and review the document or image". Being asked what a
  /// document is, with no way to look at it, is a question somebody can
  /// only answer from memory — and the case this is asked in is the one
  /// where the reader could not answer it either.
  ///
  /// Null where there is nothing to open, which is a capture whose file
  /// has gone.
  Future<void> Function()? onView,

  /// Why this is being asked, where there is a reason worth giving.
  ///
  /// `0686`: "nothing on this names a supplier" is a finding, and a
  /// question asked without it reads as the app having lost its place.
  ///
  /// It also carries the case where there is no reading at all. The
  /// default below says the reading "could not place this document",
  /// which is true of a reading that came back and placed nothing and
  /// is a lie about a scan that never reached a reader.
  String? because,
}) {
  final named = read?.supplierName?.trim();
  return showModalBottomSheet<ScanKindAnswer>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (sheetContext) => _KindSheet(
      because: because,
      namesWhom: named,
      onView: onView,
    ),
  );
}

class _KindSheet extends StatefulWidget {
  const _KindSheet({this.because, this.namesWhom, this.onView});

  final String? because;
  final String? namesWhom;
  final Future<void> Function()? onView;

  @override
  State<_KindSheet> createState() => _KindSheetState();
}

class _KindSheetState extends State<_KindSheet> {
  /// Open only once somebody says nothing on the list fits. A text box
  /// sitting under eight tiles reads as the ninth option and gets typed
  /// into by people who had a perfectly good tile to press.
  bool _typing = false;
  final _name = TextEditingController();

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _send() {
    final typed = _name.text.trim();
    if (typed.isEmpty) return;
    Navigator.of(context).pop((to: null, named: typed));
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        // The keyboard, once the box is open. Without this the field is
        // behind it on a phone, which is the only place this sheet is
        // ever seen.
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
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
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: Space.sm),
                Text(
                  widget.because ??
                      'The reading could not place this document, so '
                          'nothing has been created. Choosing here is what '
                          'decides where it goes.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                // What the paper did say, where it said anything.
                // Somebody choosing blind is somebody guessing, and the
                // name and the total are usually enough to decide.
                if (widget.namesWhom != null &&
                    widget.namesWhom!.isNotEmpty) ...[
                  const SizedBox(height: Space.sm),
                  Text(
                    'It names ${widget.namesWhom}.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
                // And the page itself, which is the only way to answer
                // this question about a document somebody photographed
                // an hour ago.
                if (widget.onView != null) ...[
                  const SizedBox(height: Space.sm),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      key: const ValueKey('scan-kind-view'),
                      onPressed: widget.onView,
                      icon: const Icon(Icons.image_outlined, size: 18),
                      label: const Text('View the document'),
                    ),
                  ),
                ],
                const SizedBox(height: Space.md),
                for (final d in offerableDestinations)
                  ListTile(
                    key: ValueKey('scan-kind-${d.name}'),
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(_iconFor(d)),
                    title: Text(d.label),
                    onTap: () =>
                        Navigator.of(context).pop((to: d, named: null)),
                  ),
                // Nothing on the list fits.
                //
                // `0709`. A payment voucher, a petty cash slip, a cash
                // bill, a delivery order in Chinese — somebody holding
                // one had no way to say so, and what the platform
                // learned was nothing. A reading that came back empty
                // is the best evidence there is for what to handle
                // next, and the person holding the paper knows exactly
                // what it is.
                if (!_typing)
                  ListTile(
                    key: const ValueKey('scan-kind-other'),
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.edit_outlined),
                    title: const Text('Something else — say what it is'),
                    onTap: () => setState(() => _typing = true),
                  )
                else ...[
                  const SizedBox(height: Space.sm),
                  TextField(
                    key: const ValueKey('scan-kind-other-name'),
                    controller: _name,
                    autofocus: true,
                    textCapitalization: TextCapitalization.sentences,
                    onChanged: (_) => setState(() {}),
                    onSubmitted: (_) => _send(),
                    decoration: const InputDecoration(
                      labelText: 'What kind of document is it?',
                      hintText: 'Payment voucher, petty cash slip, …',
                      helperText: 'In your own words. Nothing is created '
                          'from it — it is how this gets handled later.',
                    ),
                  ),
                  const SizedBox(height: Space.sm),
                  Align(
                    alignment: Alignment.centerRight,
                    child: FilledButton(
                      key: const ValueKey('scan-kind-other-send'),
                      onPressed: _name.text.trim().isEmpty ? null : _send,
                      child: const Text('Tell us'),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
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
