import 'package:flutter/material.dart';

import '../../core/format.dart';
import '../../core/theme.dart';
import '../../data/ocr_repository.dart';
import 'line_draft.dart';

/// Which part of the document a difference is about.
enum RecheckPart {
  supplierDocNo,
  documentDate,
  currency,
  lineDescription,
  lineQuantity,
  lineUnitPrice,
  lineMissing,
}

/// One thing the document says and the paper says differently.
///
/// Both sides are held as text because this is a thing somebody READS:
/// "31/08/2026" against "31/08/2026" is the comparison, not two
/// `DateTime`s. What restores it is [restore], so the dialog does not
/// have to know what any of these mean.
class PaperDifference {
  const PaperDifference({
    required this.part,
    required this.label,
    required this.onDocument,
    required this.onPaper,
    required this.restore,
    this.lineNo,
  });

  final RecheckPart part;

  /// What a person calls it — 'Unit price on line 3'.
  final String label;

  /// What the document says now. Empty means the document has nothing.
  final String onDocument;

  /// What the reader found on the page.
  final String onPaper;

  /// The line this is about, 1-based, or null for a header field.
  final int? lineNo;

  /// Puts the paper's answer back. The only thing that changes anything.
  final void Function() restore;

  /// Whether the document simply does not have this — a line that was
  /// deleted, a field that was cleared. Reads differently from a value
  /// somebody changed, and it is the case the report was about:
  /// "add what was missed out".
  bool get isMissing => onDocument.trim().isEmpty;

  /// A stable identity, so a dialog rebuilt mid-scroll keeps its ticks
  /// against the same rows.
  String get id => '${part.name}:${lineNo ?? 0}';
}

/// Half a sen, and the same tolerance `0705` compares totals on.
const double _sen = 0.005;

String _money(double v) => v.toStringAsFixed(2);

/// A quantity reads as a person typed it: 29, not 29.00.
String _count(double v) =>
    v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toString();

/// What the document says now, against what the reader found.
///
/// Asked for as a recheck beside the "AI Scan" tag: a document that was
/// filled in from a page, edited since — by a person, by assigning an
/// item, by a rounding rule — and never compared with the page again.
/// `0705`'s banner says the totals disagree; this says WHERE.
///
/// Every difference carries the way to put the paper's answer back, and
/// nothing is applied unless somebody ticks it. That is the whole shape
/// of what was asked for: "able to select item by item not all items at
/// one click, or ignore and proceed".
///
/// ## What is not a difference
///
/// A field the reader did not find. The paper cannot disagree about
/// something it never said, and reporting "the reader found no due
/// date" as a difference would put a row on every document ever read.
///
/// Lines are matched by POSITION, after folding the reader's
/// continuation rows the way `_applyScan` folds them — so the
/// comparison is against the lines that were actually put on the
/// document, not against the raw rows. A document with fewer lines than
/// the paper reports the rest as missing; one with more says nothing
/// about the extras, because a line somebody added is not the paper's
/// business.
List<PaperDifference> differencesFromPaper({
  required OcrExtraction paper,
  required List<LineDraft> lines,
  required String supplierDocNo,
  required DateTime? documentDate,
  required String currency,
  required void Function(String) setSupplierDocNo,
  required void Function(DateTime) setDocumentDate,
  required void Function(String) setCurrency,
  required void Function(LineDraft) addLine,
}) {
  final out = <PaperDifference>[];

  void header(
    RecheckPart part,
    String label,
    String? said,
    String has,
    void Function() put,
  ) {
    final paperSays = (said ?? '').trim();
    if (paperSays.isEmpty) return;
    if (paperSays == has.trim()) return;
    out.add(PaperDifference(
      part: part,
      label: label,
      onDocument: has.trim(),
      onPaper: paperSays,
      restore: put,
    ));
  }

  header(
    RecheckPart.supplierDocNo,
    'Supplier invoice no.',
    paper.documentNo,
    supplierDocNo,
    () => setSupplierDocNo(paper.documentNo!),
  );
  header(
    RecheckPart.documentDate,
    'Document date',
    paper.documentDate == null ? null : Fmt.date(paper.documentDate),
    documentDate == null ? '' : Fmt.date(documentDate),
    () => setDocumentDate(paper.documentDate!),
  );
  header(
    RecheckPart.currency,
    'Currency',
    paper.currency?.toUpperCase(),
    currency,
    () => setCurrency(paper.currency!.toUpperCase()),
  );

  final read = foldOcrContinuations(paper.lines)
      .where((l) => (l.description ?? '').trim().isNotEmpty)
      .toList();

  for (var i = 0; i < read.length; i++) {
    final r = read[i];
    final no = i + 1;

    if (i >= lines.length) {
      out.add(PaperDifference(
        part: RecheckPart.lineMissing,
        label: 'Line $no',
        onDocument: '',
        onPaper: _describe(r),
        lineNo: no,
        restore: () => addLine(_draftOf(r)),
      ));
      continue;
    }

    final line = lines[i];

    final said = r.description!.trim();
    if (said != line.description.trim()) {
      out.add(PaperDifference(
        part: RecheckPart.lineDescription,
        label: 'Description on line $no',
        onDocument: line.description.trim(),
        onPaper: said,
        lineNo: no,
        restore: () => line.description = said,
      ));
    }

    final qty = _quantityOf(r);
    if (qty != null && (qty - line.quantity).abs() >= _sen) {
      out.add(PaperDifference(
        part: RecheckPart.lineQuantity,
        label: 'Quantity on line $no',
        onDocument: _count(line.quantity),
        onPaper: _count(qty),
        lineNo: no,
        restore: () => line.quantity = qty,
      ));
    }

    final price = _priceOf(r);
    if (price != null && (price - line.unitPrice).abs() >= _sen) {
      out.add(PaperDifference(
        part: RecheckPart.lineUnitPrice,
        label: 'Unit price on line $no',
        onDocument: _money(line.unitPrice),
        onPaper: _money(price),
        lineNo: no,
        restore: () => line.unitPrice = price,
      ));
    }
  }

  return out;
}

/// The unit price a read line implies.
///
/// `lineFromScan`, and it HAS to be. This is the one place in the app
/// that compares a document against the paper it was built from, so any
/// arithmetic of its own would report a difference against a figure
/// this app itself put there — on every line where the printed amount
/// overruled a misread price column, which is exactly the case that
/// rule exists for.
///
/// It used to be a copy: `unitPrice ?? amount / quantity`. That was the
/// same arithmetic `_applyScan` had at the time, and the two moved
/// apart the moment one of them was fixed.
double? _priceOf(OcrLine line) {
  if (line.unitPrice == null && line.amount == null) return null;
  return lineFromScan(line).unitPrice;
}

/// The quantity a read line implies, by the same rule.
///
/// A printed quantity of zero becomes one — see `lineFromScan` — so a
/// recheck must not then offer to put the zero back.
double? _quantityOf(OcrLine line) =>
    line.quantity == null ? null : lineFromScan(line).quantity;

String _describe(OcrLine line) {
  final price = _priceOf(line);
  return [
    line.description!.trim(),
    if (line.quantity != null) '× ${_count(line.quantity!)}',
    if (price != null) 'at ${_money(price)}',
  ].join('  ');
}

LineDraft _draftOf(OcrLine line) => LineDraft(
      description: line.description!.trim(),
      quantity: line.quantity ?? 1,
      unitPrice: _priceOf(line) ?? 0,
    );

/// Which of the differences to put back.
///
/// Everything starts UNTICKED. What was asked for is a check, and a
/// check that changes the document by default is not one — somebody
/// pressing the obvious button must end up with the document they
/// already had.
///
/// Returns null when it is dismissed, which is "ignore and proceed".
Future<Set<String>?> askWhatToRestore(
  BuildContext context, {
  required List<PaperDifference> differences,
  required String fileName,
}) =>
    showDialog<Set<String>>(
      context: context,
      builder: (_) => _RecheckDialog(
        differences: differences,
        fileName: fileName,
      ),
    );

class _RecheckDialog extends StatefulWidget {
  const _RecheckDialog({required this.differences, required this.fileName});

  final List<PaperDifference> differences;
  final String fileName;

  @override
  State<_RecheckDialog> createState() => _RecheckDialogState();
}

class _RecheckDialogState extends State<_RecheckDialog> {
  final _take = <String>{};

  @override
  Widget build(BuildContext context) {
    final missing = widget.differences.where((d) => d.isMissing).length;

    return AlertDialog(
      title: const Text('What the paper still says'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                missing == 0
                    ? '${widget.differences.length} ${widget.differences.length == 1 ? "thing reads" : "things read"} '
                        'differently from ${widget.fileName}. Tick what to '
                        'put back.'
                    : '${widget.differences.length} '
                        '${widget.differences.length == 1 ? "difference" : "differences"} '
                        'against ${widget.fileName}, $missing of them '
                        'missing from the document. Tick what to put back.',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: Space.md),
              for (final d in widget.differences)
                _Row(
                  difference: d,
                  taken: _take.contains(d.id),
                  onChanged: (v) => setState(
                    () => v ? _take.add(d.id) : _take.remove(d.id),
                  ),
                ),
              if (widget.differences.length > 1) ...[
                const SizedBox(height: Space.sm),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(
                    key: const Key('recheck-take-all'),
                    onPressed: () => setState(() {
                      _take
                        ..clear()
                        ..addAll(widget.differences.map((d) => d.id));
                    }),
                    child: const Text('Tick everything'),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          key: const Key('recheck-ignore'),
          onPressed: () => Navigator.of(context).pop(<String>{}),
          child: const Text('Leave it as it is'),
        ),
        FilledButton(
          key: const Key('recheck-apply'),
          onPressed:
              _take.isEmpty ? null : () => Navigator.of(context).pop({..._take}),
          child: Text(
            _take.isEmpty
                ? 'Put back'
                : 'Put back ${_take.length}',
          ),
        ),
      ],
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({
    required this.difference,
    required this.taken,
    required this.onChanged,
  });

  final PaperDifference difference;
  final bool taken;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final small = Theme.of(context).textTheme.bodySmall;
    return Padding(
      padding: const EdgeInsets.only(bottom: Space.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          CheckboxListTile(
            key: Key('recheck-take-${difference.id}'),
            value: taken,
            onChanged: (v) => onChanged(v ?? false),
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            dense: true,
            title: Text(difference.label),
          ),
          Padding(
            padding: const EdgeInsets.only(left: 44),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: _Side(
                    key: Key('recheck-now-${difference.id}'),
                    caption: 'On the document',
                    value: difference.isMissing
                        ? 'Not there'
                        : difference.onDocument,
                    faded: difference.isMissing,
                    style: small,
                  ),
                ),
                const SizedBox(width: Space.sm),
                Expanded(
                  child: _Side(
                    key: Key('recheck-paper-${difference.id}'),
                    caption: 'On the paper',
                    value: difference.onPaper,
                    style: small,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Side extends StatelessWidget {
  const _Side({
    super.key,
    required this.caption,
    required this.value,
    required this.style,
    this.faded = false,
  });

  final String caption;
  final String value;
  final TextStyle? style;
  final bool faded;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          caption,
          style: style?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          value,
          style: faded
              ? style?.copyWith(fontStyle: FontStyle.italic)
              : style?.copyWith(fontWeight: FontWeight.w600),
        ),
      ],
    );
  }
}
