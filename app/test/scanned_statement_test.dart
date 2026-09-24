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
/// The assertion that matters most is about THE SIGN. A statement with
/// separate Debit and Credit columns gives the reader no sign, and a
/// wrong sign turns a withdrawal into a deposit — the most expensive
/// mistake available here.
///
/// This used to be left entirely to `import_bank_transactions`, which
/// walks the running balance (`0369`) and refuses the whole import
/// naming one line. That is the right check and the wrong remedy:
/// somebody who photographed forty lines got an error about line 12 and
/// no way forward but to type all forty in.
///
/// So the balance now DECIDES, before the rows ever leave Dart, because
/// it is arithmetic rather than opinion:
///
///     oldest-first:  amount[i]   = balance[i] - balance[i-1]
///     newest-first:  amount[i-1] = balance[i-1] - balance[i]
///
/// Agreeing in magnitude and disagreeing in sign is repaired and said
/// so. Disagreeing in MAGNITUDE is not touched — that is a missing line
/// or a misread figure, and it must still reach the refusal, because
/// rewriting an amount to make a chain close is how a statement comes
/// to reconcile against a number nobody printed.
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

    // The one field that can check the others -- and now settle them.
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

  /// The running balance settling the sign of the line beside it.
  ///
  /// This is where a photographed statement stops being a guess. Every
  /// case below is one a Malaysian retail statement actually produces,
  /// and the two that must NOT be repaired are as important as the
  /// three that must.
  group('the balance decides the sign', () {
    test('a withdrawal read as positive is put right', () {
      // Debit and Credit columns, no sign printed. The reader reads
      // magnitudes and the balance says which way each one went.
      final parse = scannedStatement(read([
        {
          'transaction_date': '01/09/2026',
          'amount': '10000.00',
          'running_balance': '10000.00',
        },
        {
          'transaction_date': '02/09/2026',
          'description': 'CHEQUE 100123',
          'amount': '250.00',
          'running_balance': '9750.00',
        },
      ]));

      expect(parse.rows[1].amount, -250.00);
      expect(parse.problems, isEmpty);
      // And said out loud. A correction nobody is told about is a
      // correction nobody can disagree with.
      expect(parse.notices.single, contains('Line 2'));
      expect(parse.notices.single, contains('money out'));
    });

    test('a deposit read as negative is put right too', () {
      final parse = scannedStatement(read([
        {
          'transaction_date': '01/09/2026',
          'amount': '1000.00',
          'running_balance': '1000.00',
        },
        {
          'transaction_date': '02/09/2026',
          'amount': '-400.00',
          'running_balance': '1400.00',
        },
      ]));

      expect(parse.rows[1].amount, 400.00);
      expect(parse.notices.single, contains('money in'));
    });

    test('a sign that was already right is left alone and said nothing '
        'about', () {
      final parse = scannedStatement(read([
        {
          'transaction_date': '01/09/2026',
          'amount': '1000.00',
          'running_balance': '1000.00',
        },
        {
          'transaction_date': '02/09/2026',
          'amount': '-250.00',
          'running_balance': '750.00',
        },
      ]));

      expect(parse.rows[1].amount, -250.00);
      expect(parse.notices, isEmpty);
      expect(parse.problems, isEmpty);
    });

    // A statement printed newest at the top. Both orders are ordinary
    // exports and `import_bank_transactions` reads the direction off
    // the dates -- so this must read it the same way, or a pair of
    // balances gets attributed to the wrong line and the "repair"
    // breaks a chain that was sound.
    test('newest-first: the pair describes the EARLIER line', () {
      final parse = scannedStatement(read([
        {
          'transaction_date': '02/09/2026',
          'description': 'CHEQUE',
          'amount': '250.00',
          'running_balance': '9750.00',
        },
        {
          'transaction_date': '01/09/2026',
          'amount': '10000.00',
          'running_balance': '10000.00',
        },
      ]));

      // Line 1 is the later date, so the movement between the two
      // balances is line 1's, undone: 10000 -> 9750 is -250.
      expect(parse.rows[0].amount, -250.00);
      expect(parse.rows[1].amount, 10000.00);
      expect(parse.notices.single, contains('Line 1'));
    });

    test('a whole statement of unsigned magnitudes comes out right', () {
      final parse = scannedStatement(read([
        {'transaction_date': '01/09/2026', 'amount': '5000.00',
         'running_balance': '5000.00'},
        {'transaction_date': '02/09/2026', 'amount': '1200.00',
         'running_balance': '3800.00'},
        {'transaction_date': '03/09/2026', 'amount': '450.50',
         'running_balance': '3349.50'},
        {'transaction_date': '04/09/2026', 'amount': '2000.00',
         'running_balance': '5349.50'},
      ]));

      expect(parse.rows.map((r) => r.amount).toList(),
          [5000.00, -1200.00, -450.50, 2000.00]);
      expect(parse.notices, hasLength(2));
      expect(parse.problems, isEmpty);
    });

    // ---------------------------------------------------------------
    // The two that must NOT be repaired
    // ---------------------------------------------------------------

    test('a magnitude that disagrees is NOT rewritten to make it close',
        () {
      // 1000 -> 700 is a movement of 300, and the line says 250. That
      // is a missing line or a misread figure. Rewriting it to -300
      // would make the chain close against a number nobody printed,
      // and the statement would then reconcile perfectly to the wrong
      // total.
      final parse = scannedStatement(read([
        {'transaction_date': '01/09/2026', 'amount': '1000.00',
         'running_balance': '1000.00'},
        {'transaction_date': '02/09/2026', 'amount': '250.00',
         'running_balance': '700.00'},
      ]));

      expect(parse.rows[1].amount, 250.00);
      expect(parse.notices, isEmpty);
      // Said BEFORE the import is attempted rather than after it is
      // refused, which is the whole difference for somebody holding
      // forty lines.
      expect(parse.problems.single, contains('Line 2'));
      expect(parse.problems.single, contains('missing'));
    });

    test('a line with no balance beside it is left exactly as read', () {
      // No balance column at all is an ordinary statement. Nothing can
      // be proved about it and nothing is claimed.
      final parse = scannedStatement(read([
        {'transaction_date': '01/09/2026', 'amount': '1000.00'},
        {'transaction_date': '02/09/2026', 'amount': '250.00'},
      ]));

      expect(parse.rows.map((r) => r.amount).toList(), [1000.00, 250.00]);
      expect(parse.notices, isEmpty);
      expect(parse.problems, isEmpty);
    });

    test('and a gap in the balance column breaks the pair, not the run',
        () {
      // Middle line has no balance, so neither pair spanning it can be
      // used -- but the pair that does not span it still can.
      final parse = scannedStatement(read([
        {'transaction_date': '01/09/2026', 'amount': '1000.00',
         'running_balance': '1000.00'},
        {'transaction_date': '02/09/2026', 'amount': '100.00'},
        {'transaction_date': '03/09/2026', 'amount': '50.00',
         'running_balance': '850.00'},
      ]));

      expect(parse.rows[1].amount, 100.00); // untouched
      expect(parse.rows[2].amount, 50.00); // untouched: no pair reaches it
      expect(parse.notices, isEmpty);
    });

    test('one line proves nothing', () {
      final parse = scannedStatement(read([
        {'transaction_date': '01/09/2026', 'amount': '250.00',
         'running_balance': '9750.00'},
      ]));
      expect(parse.rows.single.amount, 250.00);
      expect(parse.notices, isEmpty);
      expect(parse.problems, isEmpty);
    });

    // Every delta comes off the ORIGINAL balances, so a repair on one
    // line cannot move what the next line is compared against.
    test('repairs do not cascade', () {
      final parse = scannedStatement(read([
        {'transaction_date': '01/09/2026', 'amount': '1000.00',
         'running_balance': '1000.00'},
        {'transaction_date': '02/09/2026', 'amount': '300.00',
         'running_balance': '700.00'},
        {'transaction_date': '03/09/2026', 'amount': '200.00',
         'running_balance': '500.00'},
      ]));

      expect(parse.rows.map((r) => r.amount).toList(),
          [1000.00, -300.00, -200.00]);
      expect(parse.notices, hasLength(2));
    });

    test('half a sen of float noise is not a disagreement', () {
      // 0.1 + 0.2 arithmetic. Without any tolerance this would report
      // an ordinary statement as broken.
      final parse = scannedStatement(read([
        {'transaction_date': '01/09/2026', 'amount': '0.30',
         'running_balance': '0.30'},
        {'transaction_date': '02/09/2026', 'amount': '-0.10',
         'running_balance': '0.20'},
      ]));
      expect(parse.notices, isEmpty);
      expect(parse.problems, isEmpty);
    });

    test('but ONE SEN out is a disagreement, not a sign to flip', () {
      // The balance moves by 250.00 and the line reads 250.01. That is
      // a misread digit, and it is the exact case a sloppier tolerance
      // swallows: widen this to a ringgit and the line is silently
      // "corrected" to -250.00, the chain closes, and a statement
      // reconciles perfectly against a figure the bank never printed.
      final parse = scannedStatement(read([
        {'transaction_date': '01/09/2026', 'amount': '1000.00',
         'running_balance': '1000.00'},
        {'transaction_date': '02/09/2026', 'amount': '250.01',
         'running_balance': '750.00'},
      ]));

      expect(parse.rows[1].amount, 250.01); // untouched
      expect(parse.notices, isEmpty);
      expect(parse.problems.single, contains('Line 2'));
    });
  });

  /// Lines that print a day and a month and no year, which is most of
  /// them.
  ///
  /// Maybank, CIMB and Public Bank all print `03/09` or `03 SEP` on
  /// each line and put the period in the header once. `parseStatement
  /// Date` returns null for every one of those, so a photographed
  /// statement in the commonest layout there is came back as forty
  /// lines of "no date could be read" — the whole statement, unusable,
  /// with nothing on screen to say why.
  group('a line with no year on it', () {
    OcrExtraction dated(String on, List<Map<String, String>> rows) =>
        OcrExtraction.fromJson({'document_date': on, 'rows': rows});

    test('takes its year from the statement header', () {
      final parse = scannedStatement(dated('2026-09-30', [
        {'transaction_date': '03/09', 'amount': '-250.00'},
      ]));

      expect(parse.problems, isEmpty);
      expect(parse.rows.single.date, DateTime(2026, 9, 3));
    });

    test('and reads the named-month form too', () {
      final parse = scannedStatement(dated('2026-09-30', [
        {'transaction_date': '03 SEP', 'amount': '-250.00'},
        {'transaction_date': '5-Sep', 'amount': '-10.00'},
      ]));

      expect(parse.problems, isEmpty);
      expect(parse.rows[0].date, DateTime(2026, 9, 3));
      expect(parse.rows[1].date, DateTime(2026, 9, 5));
    });

    /// The case that makes this worth doing carefully rather than
    /// taking the header's year for everything.
    test('a statement crossing new year puts December in the right one',
        () {
      // Dated 5 January 2027. `28/12` is December 2026 and `03/01` is
      // January 2027. Taking the header year for both would file a
      // December transaction twelve months out, into a financial year
      // that may already be closed.
      final parse = scannedStatement(dated('2027-01-05', [
        {'transaction_date': '28/12', 'amount': '-250.00'},
        {'transaction_date': '03/01', 'amount': '-100.00'},
      ]));

      expect(parse.rows[0].date, DateTime(2026, 12, 28));
      expect(parse.rows[1].date, DateTime(2027, 1, 3));
    });

    test('and the other way, for a statement dated just before new year',
        () {
      // Dated 28 December 2026, and a line reading `02/01` is the
      // January after, not eleven months earlier.
      final parse = scannedStatement(dated('2026-12-28', [
        {'transaction_date': '02/01', 'amount': '-250.00'},
      ]));

      expect(parse.rows.single.date, DateTime(2027, 1, 2));
    });

    test('with no header date, another line on the page answers for it',
        () {
      final parse = scannedStatement(read([
        {'transaction_date': '01/09/2026', 'amount': '1000.00'},
        {'transaction_date': '03/09', 'amount': '-250.00'},
      ]));

      expect(parse.problems, isEmpty);
      expect(parse.rows[1].date, DateTime(2026, 9, 3));
    });

    test('but with nothing to anchor to, it is still reported', () {
      // Never today's year. A statement photographed in January whose
      // lines are last December would be filed a year out, silently,
      // and the only sign would be a reconciliation that never closes.
      final parse = scannedStatement(read([
        {'transaction_date': '03/09', 'amount': '-250.00'},
      ]));

      expect(parse.rows, isEmpty);
      expect(parse.problems.single, contains('no date'));
    });

    test('a month that is not a month is not a date', () {
      expect(parsePartialStatementDate('03/13'), isNull);
      expect(parsePartialStatementDate('00/09'), isNull);
      expect(parsePartialStatementDate('03 Smudge'), isNull);
      expect(parsePartialStatementDate(''), isNull);
    });

    test('and a whole date is not read as a partial one', () {
      // `6-3-26` has three fields and belongs to `parseStatementDate`.
      expect(parsePartialStatementDate('6-3-26'), isNull);
      expect(parsePartialStatementDate('2026-03-06'), isNull);
    });
  });

  /// The brought-forward row, which nearly every Malaysian statement
  /// opens with.
  ///
  /// BAKI DIBAWA KE HADAPAN, B/F, BALANCE BROUGHT FORWARD, OPENING
  /// BALANCE. It is not a transaction: a balance, a description, and no
  /// amount at all — and it used to be reported as "Line 1: no amount
  /// could be read", which is a complaint about the one line on the
  /// page that has nothing wrong with it, on the first line, where it
  /// is the first thing anybody reads about their own statement.
  ///
  /// The balance on it is the more expensive half. It anchors the
  /// chain, and without it the FIRST real line is the one line with no
  /// pair of balances either side of it — so it was the one line whose
  /// sign nothing could settle.
  group('the balance brought forward', () {
    test('is not a line, and is not complained about', () {
      final parse = scannedStatement(read([
        {'description': 'BAKI DIBAWA KE HADAPAN', 'running_balance': '5000.00'},
        {'transaction_date': '02/09/2026', 'amount': '-250.00',
         'running_balance': '4750.00'},
      ]));

      expect(parse.rows, hasLength(1));
      expect(parse.problems, isEmpty);
    });

    test('and it settles the sign of the first real line', () {
      // Without the anchor, line 1 has no pair either side of it and
      // its sign is whatever the reader guessed. With it, the movement
      // from 5000 to 4750 is arithmetic.
      final parse = scannedStatement(read([
        {'description': 'BALANCE B/F', 'running_balance': '5000.00'},
        {'transaction_date': '02/09/2026', 'description': 'CHEQUE',
         'amount': '250.00', 'running_balance': '4750.00'},
      ]));

      expect(parse.rows.single.amount, -250.00);
      expect(parse.notices.single, contains('Line 1'));
    });

    test('a dated brought-forward row is recognised too', () {
      // Some banks print a date on it. Shape and position decide, not
      // the presence of a date.
      final parse = scannedStatement(read([
        {'transaction_date': '01/09/2026', 'description': 'OPENING BALANCE',
         'running_balance': '5000.00'},
        {'transaction_date': '02/09/2026', 'amount': '250.00',
         'running_balance': '4750.00'},
      ]));

      expect(parse.rows, hasLength(1));
      expect(parse.rows.single.amount, -250.00);
      expect(parse.problems, isEmpty);
    });

    test('a brought-forward row at the foot anchors a newest-first '
        'statement', () {
      // Printed newest at the top, so the brought-forward row is at the
      // BOTTOM — and it is the ONLY thing that can settle the oldest
      // line, which is the one with no pair below it. Both signs here
      // are read wrong and both are provable.
      final parse = scannedStatement(read([
        {'transaction_date': '02/09/2026', 'amount': '250.00',
         'running_balance': '4750.00'},
        {'transaction_date': '01/09/2026', 'amount': '-1000.00',
         'running_balance': '5000.00'},
        {'description': 'BAKI B/F', 'running_balance': '4000.00'},
      ]));

      expect(parse.rows, hasLength(2));
      // 5000 -> 4750 is the newer line's -250.
      expect(parse.rows[0].amount, -250.00);
      // 4000 -> 5000 going up the page is the older line's +1000, and
      // ONLY the foot marker proves it: drop it and this line has no
      // pair of balances either side of it at all.
      expect(parse.rows[1].amount, 1000.00);
      expect(parse.notices, hasLength(2));
      expect(parse.problems, isEmpty);
    });

    test('a statement with BOTH a b/f and a c/f row uses both', () {
      // Which is how most of them are printed. The closing row sits
      // one past the last line, so the chain walk has to reach a step
      // beyond the rows it is walking -- and must not then try to
      // repair a line that is not there.
      final parse = scannedStatement(read([
        {'description': 'BAKI DIBAWA KE HADAPAN', 'running_balance': '5000.00'},
        {'transaction_date': '02/09/2026', 'amount': '250.00',
         'running_balance': '4750.00'},
        {'transaction_date': '03/09/2026', 'amount': '600.00',
         'running_balance': '4150.00'},
        {'description': 'BAKI AKHIR', 'running_balance': '4150.00'},
      ]));

      expect(parse.rows, hasLength(2));
      expect(parse.rows.map((r) => r.amount).toList(), [-250.00, -600.00]);
      expect(parse.notices, hasLength(2));
      expect(parse.problems, isEmpty);
    });

    // ---------------------------------------------------------------
    // What is NOT a brought-forward row
    // ---------------------------------------------------------------

    test('a balance with no amount in the MIDDLE is still a problem', () {
      // That is a line whose amount was unreadable, and it is exactly
      // the case the reader has to be told about: the chain will break
      // on the line after the hole.
      final parse = scannedStatement(read([
        {'transaction_date': '01/09/2026', 'amount': '1000.00',
         'running_balance': '1000.00'},
        {'transaction_date': '02/09/2026', 'description': 'SMUDGED',
         'running_balance': '700.00'},
        {'transaction_date': '03/09/2026', 'amount': '100.00',
         'running_balance': '600.00'},
      ]));

      expect(parse.rows, hasLength(2));
      expect(parse.problems.any((p) => p.contains('no amount')), isTrue);
    });

    test('a first row with neither an amount nor a balance is untouched',
        () {
      // A heading. Nothing to anchor with and nothing to complain
      // about.
      final parse = scannedStatement(read([
        {'description': 'PENYATA AKAUN'},
        {'transaction_date': '02/09/2026', 'amount': '-250.00'},
      ]));

      expect(parse.rows, hasLength(1));
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
