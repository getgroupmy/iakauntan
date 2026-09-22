import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/data/ocr_repository.dart';
import 'package:iakauntan/src/features/banking/statement_import.dart';

/// A bank statement that was photographed rather than exported.
///
/// `0682` gave a scan target the ability to repeat, so the reader
/// answers a statement with an array of rows keyed by
/// `bank_transactions` column names — which is what
/// `import_bank_transactions` already takes. Nothing translates between
/// them. What this does is COERCE: the reader is asked for what is
/// PRINTED, so a date arrives as `03/09/2026` and an amount as
/// `1,900.00` or `(250.00)`.
///
/// The assertion that matters most is about what this deliberately does
/// NOT do. A statement with separate Debit and Credit columns gives the
/// reader no sign, and a wrong sign turns a withdrawal into a deposit —
/// the most expensive mistake available here. Nothing in Dart can tell.
/// What can tell is the running balance, which `0369` checks line by
/// line inside the RPC, so the balance is passed through whenever the
/// reader gave one. Dropping it would disarm the only check there is.
void main() {
  OcrExtraction read(List<Map<String, String>> rows) =>
      OcrExtraction.fromJson({'rows': rows});

  group('reading a photographed statement', () {
    test('a Malaysian statement line becomes an importable row', () {
      final parse = scannedStatement(read([
        {
          'transaction_date': '03/09/2026',
          'description': 'TRANSFER TO LIM HARDWARE',
          'amount': '-1,250.00',
          'running_balance': '18,400.50',
        },
      ]));

      expect(parse.problems, isEmpty);
      final row = parse.rows.single;
      // Day-first, because that is what every local bank prints.
      expect(row.date, DateTime(2026, 9, 3));
      expect(row.amount, -1250.00);
      expect(row.description, 'TRANSFER TO LIM HARDWARE');
      expect(row.balance, 18400.50);
    });

    test('and goes out in the shape the RPC takes', () {
      final parse = scannedStatement(read([
        {'transaction_date': '03/09/2026', 'amount': '10.00'},
      ]));
      expect(parse.rows.single.toJson()['transaction_date'], '2026-09-03');
    });

    // Statements write a withdrawal both ways, and a photograph of one
    // carries whichever the bank chose.
    test('brackets are a withdrawal, as on a printed statement', () {
      final parse = scannedStatement(read([
        {'transaction_date': '01/09/2026', 'amount': '(250.00)'},
      ]));
      expect(parse.rows.single.amount, -250.00);
    });

    test('RM in front of the figure is not part of the figure', () {
      final parse = scannedStatement(read([
        {'transaction_date': '01/09/2026', 'amount': 'RM 1,900.00'},
      ]));
      expect(parse.rows.single.amount, 1900.00);
    });

    // The one field that can check the others. Dropping it would leave
    // the sign of every line unverifiable.
    test('the running balance is carried through, never dropped', () {
      final parse = scannedStatement(read([
        {
          'transaction_date': '01/09/2026',
          'amount': '-250.00',
          'running_balance': '9,750.00',
        },
      ]));
      expect(parse.rows.single.toJson()['running_balance'], 9750.00);
    });

    // An administrator may reasonably tick `value_date` instead: both
    // are dates on the paper and a statement often prints only one.
    test('value_date answers when transaction_date was not ticked', () {
      final parse = scannedStatement(read([
        {'value_date': '05/09/2026', 'amount': '10.00'},
      ]));
      expect(parse.rows.single.date, DateTime(2026, 9, 5));
    });
  });

  group('lines that cannot be read', () {
    // Said, not swallowed. A statement that imports 38 of 40 lines
    // quietly reconciles to the wrong number.
    test('an unreadable date is reported with its line number', () {
      final parse = scannedStatement(read([
        {'transaction_date': '01/09/2026', 'amount': '10.00'},
        {'transaction_date': 'smudged', 'amount': '20.00'},
      ]));
      expect(parse.rows, hasLength(1));
      expect(parse.problems.single, contains('Line 2'));
      expect(parse.problems.single, contains('smudged'));
    });

    test('an unreadable amount is too', () {
      final parse = scannedStatement(read([
        {'transaction_date': '01/09/2026', 'amount': 'RM ???'},
      ]));
      expect(parse.rows, isEmpty);
      expect(parse.problems.single, contains('no amount'));
    });

    // A row that carries neither is the reader's blank line, not a
    // failure — reporting it would fill the list with noise about
    // nothing and bury the two lines that really were unreadable.
    test('a row with neither a date nor an amount is silent', () {
      final parse = scannedStatement(read([
        {'description': 'BROUGHT FORWARD'},
      ]));
      expect(parse.rows, isEmpty);
      expect(parse.problems, isEmpty);
    });

    // A line with a date and no amount IS a failure: something was
    // printed on that row and it was not read.
    test('a dated row with no amount is reported', () {
      final parse = scannedStatement(read([
        {'transaction_date': '01/09/2026', 'description': 'CHARGES'},
      ]));
      expect(parse.problems.single, contains('no amount'));
    });
  });

  group('nothing to read', () {
    test('a null reading is empty rather than a crash', () {
      final parse = scannedStatement(null);
      expect(parse.rows, isEmpty);
      expect(parse.problems, isEmpty);
    });

    // Every bill, every receipt, every name card. `rows` is empty for
    // all of them, and the dialog uses exactly this to say "that
    // photograph was not a statement" rather than importing nothing.
    test('a reading that was not a statement is empty', () {
      final parse = scannedStatement(
        OcrExtraction.fromJson(const {'supplier_name': 'Lim Hardware'}),
      );
      expect(parse.rows, isEmpty);
      expect(parse.problems, isEmpty);
    });
  });

  /// Which source the dialog previews and imports.
  ///
  /// Not merged, and not "the last one touched". A photograph and a
  /// paste are two readings of what is almost certainly the same
  /// statement, so importing both puts every line in twice under two
  /// slightly different descriptions -- which is the one case
  /// `import_bank_transactions` deduplicates worst, because the
  /// descriptions differ just enough for its key to miss.
  group('three sources, one statement', () {
    const csv = 'Date,Description,Amount\n01/09/2026,OPENING,1900.00\n';

    test('nothing typed and nothing photographed previews nothing', () {
      expect(statementPreview(null, ''), isNull);
      expect(statementPreview(null, '   \n  '), isNull);
    });

    test('a paste on its own is what gets previewed', () {
      final preview = statementPreview(null, csv);
      expect(preview, isNotNull);
      expect(preview!.rows, hasLength(1));
      expect(preview.rows.single.amount, 1900.00);
    });

    test('a photograph wins over a paste sitting underneath it', () {
      final shot = scannedStatement(OcrExtraction.fromJson(const {
        'rows': [
          {'transaction_date': '03/09/2026', 'amount': '-250.00'},
        ],
      }));

      final preview = statementPreview(shot, csv);
      expect(preview, isNotNull);
      // One row, and it is the photographed one. Take the paste
      // instead and this is 1900; merge them and it is two rows.
      expect(preview!.rows, hasLength(1));
      expect(preview.rows.single.amount, -250.00);
    });

    test('and clearing the photograph gives the paste back', () {
      final preview = statementPreview(null, csv);
      expect(preview!.rows.single.amount, 1900.00);
    });
  });
}
