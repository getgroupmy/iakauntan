import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/features/imports/file_shape.dart';
import 'package:iakauntan/src/features/imports/import_screen.dart';

/// Which importer a file is actually for.
///
/// The report this exists for: a chart of accounts exported from this
/// product, uploaded under Contacts, previewed clean and offered to
/// import. It would have created eighty-eight customers called
/// "ASSETS", "Cash in Hand" and "Accumulated Depreciation" — the
/// contacts importer needs only a `name`, and a chart has one in every
/// row.
///
/// The header of that exact file is the fixture below, character for
/// character, because the assertion worth having is about the file
/// somebody actually held.
void main() {
  /// `guaman-aziz-rakan-chart-of-accounts-2026-09-09.csv`, as exported.
  const exportedChart = [
    'code',
    'name',
    'account_type',
    'account_subtype',
    'is_group',
    'is_active',
    'current_balance',
  ];

  FileShape under(ImportKind kind, List<String> headers) =>
      identifyFile(selected: kind, headers: headers);

  group('the chart uploaded under contacts', () {
    test('is identified as a chart', () {
      expect(under(ImportKind.contacts, exportedChart).looksLike,
          ImportKind.accounts);
    });

    test('and is stopped rather than warned about', () {
      // The file carries three fingerprints of the chart importer and
      // none of the contacts one. There is nothing to weigh.
      expect(fileShapeBlocks(under(ImportKind.contacts, exportedChart)),
          isTrue);
    });

    test('the message names the columns that prove it', () {
      final warning =
          fileShapeWarning(under(ImportKind.contacts, exportedChart))!;
      expect(warning, contains('Chart of accounts'));
      expect(warning, contains('not Contacts'));
      // Facts somebody can check against the file in front of them,
      // rather than "this looks wrong".
      expect(warning, contains('account_type'));
      expect(warning, contains('account_subtype'));
      expect(warning, contains('is_group'));
    });

    test('and under the chart importer it passes without a word', () {
      final shape = under(ImportKind.accounts, exportedChart);
      expect(shape.looksLike, isNull);
      expect(fileShapeWarning(shape), isNull);
      expect(fileShapeBlocks(shape), isFalse);
    });
  });

  group('what the round trip loses', () {
    test('the export writes two columns the importer does not read', () {
      // Said out loud rather than dropped silently: an imported account
      // is active, and its balance comes from the ledger.
      final note = ignoredColumnsNote(ImportKind.accounts, exportedChart)!;
      expect(note, contains('is_active'));
      expect(note, contains('current_balance'));
      expect(note, contains('left out'));
    });

    test('and a file with nothing spare says nothing', () {
      expect(
        ignoredColumnsNote(ImportKind.accounts,
            ['code', 'name', 'account_subtype']),
        isNull,
      );
    });
  });

  group('the other importers recognise their own', () {
    test('a contact file under contacts is fine', () {
      final shape = under(ImportKind.contacts,
          ['code', 'name', 'contact_type', 'credit_limit', 'email']);
      expect(shape.looksLike, isNull);
      expect(fileShapeWarning(shape), isNull);
    });

    test('a contact file under the chart is stopped', () {
      final shape = under(ImportKind.accounts,
          ['code', 'name', 'contact_type', 'credit_limit']);
      expect(shape.looksLike, ImportKind.contacts);
      expect(fileShapeBlocks(shape), isTrue);
    });

    test('an item file under contacts is stopped', () {
      final shape =
          under(ImportKind.contacts, ['code', 'name', 'unit_price', 'uom_code']);
      expect(shape.looksLike, ImportKind.items);
      expect(fileShapeBlocks(shape), isTrue);
    });

    test('open invoices under opening balances are stopped', () {
      final shape = under(ImportKind.openingBalances,
          ['doc_no', 'contact_code', 'doc_date', 'outstanding_amount']);
      expect(shape.looksLike, ImportKind.openInvoices);
      expect(fileShapeBlocks(shape), isTrue);
    });
  });

  group('what it does not do', () {
    test('a file of only shared columns is nobody’s to claim', () {
      // `code` and `name` belong to everybody and prove nothing. This
      // is exactly the file the contacts importer should go on
      // accepting, and blocking it would break the ordinary case to
      // catch the odd one.
      final shape = under(ImportKind.contacts, ['code', 'name']);
      expect(shape.looksLike, isNull);
      expect(fileShapeBlocks(shape), isFalse);
    });

    test('a file carrying both fingerprints is the person’s call', () {
      // Contacts by `credit_limit`, chart by `account_subtype`. The
      // screen says so and does not stop it: ambiguity is not the
      // screen's to resolve.
      final shape = under(ImportKind.contacts,
          ['code', 'name', 'credit_limit', 'account_subtype']);
      expect(fileShapeBlocks(shape), isFalse);
    });

    test('an unrecognisable file is not blamed on another importer', () {
      final shape = under(ImportKind.contacts, ['alpha', 'beta', 'gamma']);
      expect(shape.looksLike, isNull);
      expect(fileShapeWarning(shape), isNull);
    });

    test('the headings a spreadsheet writes are still understood', () {
      // The aliases do the work: "Customer Name" is `name`, "Credit
      // Limit" is `credit_limit`. A detector that only knew the
      // canonical spellings would call every real export foreign.
      final shape = under(ImportKind.contacts,
          ['Customer Code', 'Customer Name', 'Credit Limit']);
      expect(shape.looksLike, isNull);
      expect(shape.recognised[ImportKind.contacts]!.length, 3);
    });
  });

  test('every importer has a vocabulary', () {
    for (final kind in ImportKind.values) {
      expect(importColumnsFor(kind), isNotEmpty,
          reason: '$kind recognises no columns, so nothing can be '
              'identified as belonging to it');
    }
  });
}
