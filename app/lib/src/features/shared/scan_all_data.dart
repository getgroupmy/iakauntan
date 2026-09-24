import 'package:flutter/material.dart';

import '../../core/format.dart';
import '../../core/theme.dart';
import '../../data/ocr_repository.dart';
import 'receipt_text.dart';

/// Everything the reader saw, and a way to put it where it belongs.
///
/// The form shows what the reading *made of* a document. This shows the
/// document. They are different things, and the gap between them is
/// where the work is: a reader that finds nine fields out of eleven has
/// done well, and the two it missed are usually printed plainly on the
/// page — just not under a label anything recognised.
///
/// So rather than retyping them, the line is already here: pick it, say
/// which field it is, and it goes in. What a machine cannot infer, a
/// person can point at.
///
/// Returns the reading with whatever was assigned. Null if the page was
/// left without keeping the changes.
Future<OcrExtraction?> showAllData(
  BuildContext context,
  OcrExtraction read,
) =>
    Navigator.of(context).push<OcrExtraction>(MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => _AllDataPage(read: read),
    ));

/// A field a line of text can be assigned to.
///
/// Every field the form has, because the whole point is to reach the one
/// the reader missed, and there is no telling in advance which that is.
enum ScanField {
  supplier('Supplier'),
  registrationNo('SSM no'),
  taxNumber('Tax number'),
  email('Email'),
  phone('Phone'),
  address('Address'),
  documentNo('Document no'),
  date('Date'),
  currency('Currency'),
  subtotal('Subtotal'),
  tax('Tax'),
  total('Total'),
  line('Add as a line');

  const ScanField(this.label);

  final String label;
}

/// Puts one line of text into one field.
///
/// Money is parsed, a date is read the way the parser reads one, a
/// currency is upper-cased. Returns null when the text cannot be that
/// kind of field at all — `TERIMA KASIH` is not a total, and quietly
/// storing a zero for it would be worse than refusing.
OcrExtraction? assignToField(
  OcrExtraction read,
  ScanField field,
  String text,
) {
  final value = text.trim();
  if (value.isEmpty) return null;

  switch (field) {
    case ScanField.supplier:
      return read.copyWith(supplierName: value);
    case ScanField.registrationNo:
      return read.copyWith(supplierRegistrationNo: value);
    case ScanField.taxNumber:
      return read.copyWith(supplierTaxId: value);
    case ScanField.email:
      return read.copyWith(supplierEmail: value);
    case ScanField.phone:
      return read.copyWith(supplierPhone: value);
    case ScanField.address:
      // Appended rather than replaced. An address is several lines and
      // they are assigned one at a time, so the second would otherwise
      // wipe out the first.
      final existing = read.supplierAddress;
      return read.copyWith(
        supplierAddress: existing == null || existing.isEmpty
            ? value
            : '$existing\n$value',
      );
    case ScanField.documentNo:
      return read.copyWith(documentNo: value);
    case ScanField.date:
      final date = parseReceiptDate(value);
      return date == null ? null : read.copyWith(documentDate: date);
    case ScanField.currency:
      return read.copyWith(currency: value.toUpperCase());
    case ScanField.subtotal:
      final amount = parseAmountText(value);
      return amount == null ? null : read.copyWith(subtotal: amount);
    case ScanField.tax:
      final amount = parseAmountText(value);
      return amount == null ? null : read.copyWith(taxAmount: amount);
    case ScanField.total:
      final amount = parseAmountText(value);
      return amount == null ? null : read.copyWith(totalAmount: amount);
    case ScanField.line:
      final line = parseReceiptLine(value);
      if (line.description == null && line.amount == null) return null;
      return read.copyWith(lines: [...read.lines, line]);
  }
}

/// The document as a list of lines, whatever the reader gave us.
///
/// The on-device readers hand back the text of the page. The two LLM
/// readers answer with fields and no text at all — so rather than an
/// empty screen that looks like a failure, what they *did* return is
/// listed instead, which is still every scrap of data there is to
/// reassign.
List<String> allDataLines(OcrExtraction read) {
  final raw = read.rawText;
  if (raw != null && raw.trim().isNotEmpty) {
    return raw
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();
  }

  return [
    for (final value in [
      read.supplierName,
      read.supplierRegistrationNo,
      read.supplierTaxId,
      read.supplierEmail,
      read.supplierPhone,
      read.supplierAddress,
      read.documentNo,
      read.currency,
    ])
      if (value != null && value.trim().isNotEmpty) value.trim(),
    if (read.documentDate != null) Fmt.date(read.documentDate),
    for (final line in read.lines)
      [
        line.description,
        if (line.amount != null) line.amount!.toStringAsFixed(2),
      ].whereType<String>().join('  '),
    // The rows a destination that takes them came back with — a bank
    // statement IS its transactions, and this screen listed none of
    // them. A statement whose every line was read showed "Nothing came
    // back at all".
    //
    // Sorted by key so the columns line up down the list; a map has no
    // order and a list that reshuffles between openings is one nobody
    // trusts, which is the same reason `readerColumns` sorts.
    for (final row in read.rows)
      [
        for (final k in row.keys.toList()..sort())
          if ((row[k] ?? '').trim().isNotEmpty) row[k]!.trim(),
      ].join('  '),
    for (final amount in [read.subtotal, read.taxAmount, read.totalAmount])
      if (amount != null) amount.toStringAsFixed(2),
  ];
}

class _AllDataPage extends StatefulWidget {
  const _AllDataPage({required this.read});

  final OcrExtraction read;

  @override
  State<_AllDataPage> createState() => _AllDataPageState();
}

class _AllDataPageState extends State<_AllDataPage> {
  late OcrExtraction _read = widget.read;
  late final List<TextEditingController> _lines = [
    for (final line in allDataLines(widget.read))
      TextEditingController(text: line),
  ];

  /// Which field each line was last put into, so the screen says what it
  /// did rather than leaving somebody to check the form afterwards.
  final _assigned = <int, ScanField>{};

  @override
  void dispose() {
    for (final c in _lines) {
      c.dispose();
    }
    super.dispose();
  }

  bool get _fromText =>
      widget.read.rawText != null && widget.read.rawText!.trim().isNotEmpty;

  void _assign(int index, ScanField field) {
    final next = assignToField(_read, field, _lines[index].text);
    if (next == null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(
          field == ScanField.date
              ? 'That is not a date this can read. Edit it to something like '
                  '14/08/2026 first.'
              : 'That is not a figure. Edit it to just the number first.',
        ),
      ));
      return;
    }
    setState(() {
      _read = next;
      _assigned[index] = field;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('All data'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, _read),
            child: const Text('Done'),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(Space.lg),
        children: [
          Text(
            _fromText
                ? 'Everything the reader saw, in the order it was printed. '
                    'Tap a line to correct it, then assign it to a field.'
                : 'This reader answers with fields rather than with the text '
                    'of the page, so what it found is listed here. Tap a line '
                    'to correct it, then assign it to a field.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: Space.lg),
          _Assigned(read: _read),
          const Divider(height: Space.xl),
          if (_lines.isEmpty)
            Text(
              'Nothing came back at all. Type the figures into the form '
              'instead — the document is attached either way.',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          for (var i = 0; i < _lines.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: Space.sm),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      TextField(
                        key: ValueKey('all-data-$i'),
                        controller: _lines[i],
                        style: const TextStyle(fontSize: 13),
                        minLines: 1,
                        maxLines: 3,
                        decoration: const InputDecoration(isDense: true),
                      ),
                      if (_assigned[i] != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(
                            'Assigned to ${_assigned[i]!.label}',
                            style: TextStyle(
                              fontSize: 11,
                              color: context.colors.success,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                PopupMenuButton<ScanField>(
                  tooltip: 'Assign this to a field',
                  icon: const Icon(Icons.playlist_add, size: 20),
                  onSelected: (field) => _assign(i, field),
                  itemBuilder: (_) => [
                    for (final field in ScanField.values)
                      PopupMenuItem(
                        value: field,
                        child: Text(field.label),
                      ),
                  ],
                ),
              ]),
            ),
        ],
      ),
    );
  }
}

/// What the reading holds at this moment.
///
/// On screen while assigning, because the question being answered is
/// "which field is still empty" and answering it from memory is how the
/// same line gets assigned twice.
class _Assigned extends StatelessWidget {
  const _Assigned({required this.read});

  final OcrExtraction read;

  @override
  Widget build(BuildContext context) {
    final rows = <(String, String?)>[
      ('Supplier', read.supplierName),
      ('SSM no', read.supplierRegistrationNo),
      ('Tax number', read.supplierTaxId),
      ('Email', read.supplierEmail),
      ('Phone', read.supplierPhone),
      ('Address', read.supplierAddress),
      ('Document no', read.documentNo),
      ('Date', read.documentDate == null ? null : Fmt.date(read.documentDate)),
      ('Currency', read.currency),
      ('Subtotal', read.subtotal == null ? null : Fmt.money(read.subtotal!)),
      ('Tax', read.taxAmount == null ? null : Fmt.money(read.taxAmount!)),
      ('Total', read.totalAmount == null ? null : Fmt.money(read.totalAmount!)),
      ('Lines', read.lines.isEmpty ? null : '${read.lines.length}'),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('The form so far',
            style: Theme.of(context).textTheme.labelLarge),
        const SizedBox(height: Space.sm),
        for (final (label, value) in rows)
          Padding(
            padding: const EdgeInsets.only(bottom: 2),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              SizedBox(
                width: 104,
                child:
                    Text(label, style: Theme.of(context).textTheme.bodySmall),
              ),
              Expanded(
                child: Text(
                  value ?? 'Still empty',
                  style: TextStyle(
                    fontSize: 13,
                    color: value == null ? context.scheme.onSurfaceVariant : null,
                    fontStyle: value == null ? FontStyle.italic : null,
                  ),
                ),
              ),
            ]),
          ),
      ],
    );
  }
}
