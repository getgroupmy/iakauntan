import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/features/imports/file_shape.dart';
import 'package:iakauntan/src/features/imports/import_screen.dart';
import 'package:iakauntan/src/features/imports/import_template.dart';

/// The transaction importer, and the file it is most likely to be
/// confused with. `0631`.
///
/// It shares almost its whole vocabulary with Open invoices — document
/// number, customer, date, currency, reference, description — and the
/// two do completely different things. One brings in a balance still
/// owed; the other brings in the document itself, line by line. A file
/// of one dropped on the other is the mistake this has to catch, and it
/// is the mistake `file_shape.dart` was written for after a chart of
/// accounts was imported as eighty-eight customers.
void main() {
  FileShape under(ImportKind kind, List<String> headers) =>
      identifyFile(selected: kind, headers: headers);

  /// What a package actually exports: one row per line.
  const transactionFile = [
    'doc_no',
    'contact_code',
    'doc_date',
    'description',
    'quantity',
    'unit_price',
  ];

  /// And what an open-item file looks like: one row per document, with
  /// what is left on it.
  const openInvoiceFile = [
    'doc_no',
    'contact_code',
    'doc_date',
    'due_date',
    'outstanding_amount',
  ];

  group('a transaction file under the open-invoice importer', () {
    test('is identified as transactions', () {
      expect(
        under(ImportKind.openInvoices, transactionFile).looksLike,
        ImportKind.salesTransactions,
      );
    });

    test('and is stopped rather than warned about', () {
      // Open invoices reads four of these six and would import them as
      // balances of nothing: there is no `outstanding_amount` in the
      // file, so every invoice would come in owing zero.
      expect(
        fileShapeBlocks(under(ImportKind.openInvoices, transactionFile)),
        isTrue,
      );
    });

    test('and the message names the columns that prove it', () {
      final warning =
          fileShapeWarning(under(ImportKind.openInvoices, transactionFile))!;
      expect(warning, contains('Sales transactions'));
      expect(warning, contains('quantity'));
      expect(warning, contains('unit_price'));
    });

    test('while under its own importer it passes without a word', () {
      expect(
        fileShapeWarning(under(ImportKind.salesTransactions, transactionFile)),
        isNull,
      );
    });
  });

  group('an open-invoice file under the transaction importer', () {
    // The other direction, and it must NOT be a superset either way:
    // `outstanding_amount` is a column only the open-item importer
    // reads, so this is caught on its own evidence rather than by luck.
    test('is identified as open invoices', () {
      expect(
        under(ImportKind.salesTransactions, openInvoiceFile).looksLike,
        ImportKind.openInvoices,
      );
    });

    test('and the evidence is the column about money still owed', () {
      expect(
        under(ImportKind.salesTransactions, openInvoiceFile).evidence,
        contains('outstanding_amount'),
      );
    });
  });

  group('the purchase side, and the column that makes it different', () {
    /// `supplier_doc_no` is what is printed on the paper, and `0628`
    /// reads it to decide whether the same bill has arrived twice.
    const purchaseFile = [
      'doc_no',
      'supplier_doc_no',
      'contact_code',
      'doc_date',
      'description',
      'quantity',
      'unit_price',
    ];

    test('a purchase file under the sales importer is caught', () {
      expect(
        under(ImportKind.salesTransactions, purchaseFile).looksLike,
        ImportKind.purchaseTransactions,
      );
      expect(
        under(ImportKind.salesTransactions, purchaseFile).evidence,
        contains('supplier_doc_no'),
      );
    });

    test('and under its own importer it passes', () {
      expect(
        fileShapeWarning(
          under(ImportKind.purchaseTransactions, purchaseFile),
        ),
        isNull,
      );
    });

    // Not required, deliberately: a subscription receipt or a toll
    // carries no number of the supplier's, and refusing the file over
    // it would refuse the ordinary case to protect the duplicate check.
    test('the supplier’s number is read but not required', () {
      expect(
        importColumnsFor(ImportKind.purchaseTransactions).keys,
        contains('supplier_doc_no'),
      );
      expect(
        requiredColumnsFor(ImportKind.purchaseTransactions),
        isNot(contains('supplier_doc_no')),
      );
    });

    test('and a bill file under Open bills is still caught', () {
      // They share `doc_no`, `supplier_doc_no`, `contact_code` and
      // `doc_date`; what tells them apart is that one carries lines.
      expect(
        under(ImportKind.openBills, purchaseFile).looksLike,
        ImportKind.purchaseTransactions,
      );
    });
  });

  group('the importer knows its own file', () {
    test('every column of the template is one it reads', () {
      final columns = importTemplateColumns(ImportKind.salesTransactions);
      final shape = under(ImportKind.salesTransactions, columns);
      expect(
        shape.recognised[ImportKind.salesTransactions],
        columns.toSet(),
      );
    });

    // The four a line cannot do without. `doc_no` above all: it is what
    // groups the lines of one document together, so a file missing it
    // is not a file of documents at all — every row would become its
    // own invoice.
    test('and it refuses a file missing any of the four', () {
      expect(requiredColumnsFor(ImportKind.salesTransactions), const [
        'doc_no',
        'contact_code',
        'doc_date',
        'unit_price',
      ]);
    });

    test('and every required column is one it can read', () {
      final vocabulary = importColumnsFor(ImportKind.salesTransactions).keys;
      for (final c in requiredColumnsFor(ImportKind.salesTransactions)) {
        expect(vocabulary, contains(c));
      }
    });

    // The same rule for every importer, not only this one: a column the
    // screen refuses a file without, and then cannot read, is a file
    // nobody can ever import.
    test('and that holds for every importer', () {
      for (final kind in ImportKind.values) {
        final vocabulary = importColumnsFor(kind).keys;
        for (final c in requiredColumnsFor(kind)) {
          expect(
            vocabulary,
            contains(c),
            reason: '${importKindLabel(kind)} requires $c and cannot read it',
          );
        }
      }
    });

    // `doc_type` deliberately has no aliases worth guessing at: a
    // column called "type" in an export is as likely to be the item
    // type or the tax type, and reading it as the document type would
    // turn rows into credit notes without saying so.
    test('and "type" on its own is not read as the kind of document', () {
      final shape = under(ImportKind.salesTransactions, const ['type']);
      expect(shape.recognised[ImportKind.salesTransactions], isEmpty);
    });
  });
}
