import '../../core/format.dart';
import '../../data/ocr_repository.dart';
import 'scan_destination.dart';

/// One thing the reader found, and the column it fills.
class ReadField {
  const ReadField({
    required this.label,
    required this.column,
    required this.value,
  });

  /// What a person calls it.
  final String label;

  /// Where it lands, as `table.column`. This is the part somebody
  /// cannot get from the result dialog: a reading shown as a list of
  /// labels says what was FOUND, and says nothing about what it is
  /// about to change.
  final String column;

  final String value;
}

/// The reading, field by field, against the columns it fills.
///
/// Two sources, and they answer different questions:
///
///  * [OcrExtraction.fields] is what the READER was asked for, keyed by
///    column name already — `0681` gives it the destination's own
///    columns and their descriptions. Where it answered, that is the
///    authoritative mapping and nothing here has to guess.
///  * The parsed fields on [OcrExtraction] are what the app made of the
///    document afterwards. They are what actually fills the form for
///    every destination, so they are shown even where the reader
///    answered in columns, and mapped by [destination] because the same
///    supplier name is `contacts.name` on one and
///    `purchase_documents.contact_id` on another.
///
/// Empty values are dropped throughout. "The tax number is not printed
/// on this receipt" is a useful answer and a blank row is not.
List<ReadField> readingColumns(OcrExtraction? read, ScanDestination to) {
  if (read == null) return const [];
  final out = <ReadField>[];

  void add(String label, String column, Object? value) {
    if (value == null) return;
    final text = value is DateTime ? Fmt.date(value) : value.toString().trim();
    if (text.isEmpty) return;
    out.add(ReadField(label: label, column: column, value: text));
  }

  final table = to.table;

  switch (to) {
    case ScanDestination.contact:
      add('Name', '$table.name', read.supplierName);
      add('Tax number (TIN)', '$table.tax_id', read.supplierTaxId);
      add('Registration number', '$table.registration_no',
          read.supplierRegistrationNo);
      add('Email', '$table.email', read.supplierEmail);
      add('Phone', '$table.phone', read.supplierPhone);
      add('Address', '$table.address_line1', read.supplierAddress);

    case ScanDestination.expense:
      add('Paid to', '$table.contact_id', read.supplierName);
      add('Reference', '$table.reference', read.documentNo);
      add('Date', '$table.expense_date', read.documentDate);
      add('Currency', '$table.currency', read.currency);
      add('Amount before tax', '$table.amount', read.subtotal);
      add('Tax', '$table.tax_amount', read.taxAmount);
      add('Total', '$table.total_amount', read.totalAmount);

    case ScanDestination.bankStatement:
      // A statement has no header fields worth mapping — it is its
      // rows, and those are shown separately. Saying nothing here beats
      // mapping a supplier name onto a table that has no such column.
      break;

    case ScanDestination.bill:
    case ScanDestination.purchaseOrder:
    case ScanDestination.goodsReceived:
    case ScanDestination.invoice:
    case ScanDestination.unknown:
      final isSales = to == ScanDestination.invoice;
      add(isSales ? 'Customer' : 'Supplier', '$table.contact_id',
          read.supplierName);
      // Their number for it, and only on the buying side: a sales
      // document's number is this company's own sequence, so writing
      // the read one there would file a customer's reference as our
      // invoice number.
      if (!isSales) {
        add('Their document number', '$table.supplier_doc_no',
            read.documentNo);
      }
      add('Date', '$table.doc_date', read.documentDate);
      add('Currency', '$table.currency', read.currency);
      add('Subtotal', '$table.subtotal', read.subtotal);
      add('Tax', '$table.tax_amount', read.taxAmount);
      add('Total', '$table.total_amount', read.totalAmount);
  }

  return out;
}

/// What the reader itself put in each of the destination's columns.
///
/// Already keyed by column name — `0681` hands the reader the
/// destination's own column list — so this is a straight listing with
/// no mapping to get wrong. Sorted, because a map has no order and a
/// list that reshuffles between openings is one nobody trusts.
List<ReadField> readerColumns(OcrExtraction? read, ScanDestination to) {
  final fields = read?.fields;
  if (fields == null || fields.isEmpty) return const [];
  final keys = fields.keys.toList()..sort();
  return [
    for (final k in keys)
      if ((fields[k] ?? '').trim().isNotEmpty)
        ReadField(
          label: _humanise(k),
          column: '${to.table}.$k',
          value: fields[k]!.trim(),
        ),
  ];
}

/// `supplier_tax_id` becomes `Supplier tax id`.
///
/// Not a lookup against `scan_target_fields`, deliberately: that table
/// holds the DESCRIPTION the reader is given — a paragraph telling it
/// what to look for — which is prose for a machine and far too long to
/// put beside a value. The column name is what a person needs, and this
/// only makes it readable.
String _humanise(String column) {
  final words = column.split('_').where((w) => w.isNotEmpty).toList();
  if (words.isEmpty) return column;
  final first = words.first;
  return [
    first[0].toUpperCase() + first.substring(1),
    ...words.skip(1),
  ].join(' ');
}
