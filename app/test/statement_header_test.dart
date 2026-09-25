import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/data/ocr_repository.dart';
import 'package:iakauntan/src/features/banking/statement_import.dart';

/// What a statement says about ITSELF, as opposed to about any line.
///
/// ## The check that could not be made
///
/// `import_bank_transactions` walks the running balance from each line
/// to the next and refuses the import naming the line that does not
/// bridge. That is a good check and it has a hole in it: it only ever
/// compares two lines that are BOTH present.
///
/// A line missing from the end of the statement, a second page never
/// read, a first line never returned — each of those leaves a chain
/// that closes perfectly, because what is missing is missing from both
/// sides of every comparison that remains. The statement reconciles to
/// a number nobody printed.
///
/// Opening plus every amount reaching closing is the check that spans
/// the whole document, and until the reader was asked for the two
/// balances it could not be made at all. One sen of tolerance, which is
/// the acceptance matrix's own figure.
///
/// ## And nothing is adjusted to make it agree
///
/// The reader is told to give the two balances AS PRINTED or to give
/// null. A closing balance worked out by adding up the rows agrees with
/// the rows by construction and checks nothing whatsoever — it is the
/// accounting equivalent of marking your own homework.
void main() {
  OcrExtraction read(
    List<Map<String, String>> rows, {
    Map<String, String>? statement,
  }) =>
      OcrExtraction.fromJson({
        'rows': rows,
        if (statement != null) 'statement': statement,
      });

  List<Map<String, String>> threeLines() => [
        {
          'transaction_date': '01/08/2026',
          'description': 'DUITNOW TRANSFER',
          'amount': '1000.00',
        },
        {
          'transaction_date': '02/08/2026',
          'description': 'SUPPLIER PAYMENT',
          'amount': '-250.00',
        },
        {
          'transaction_date': '03/08/2026',
          'description': 'BANK CHARGE',
          'amount': '-50.00',
        },
      ];

  group('the statement foots, or says it does not', () {
    test('opening plus the lines reaching closing is silent', () {
      // 500 + 1000 - 250 - 50 = 1200.
      final parse = scannedStatement(read(threeLines(), statement: {
        'opening_balance': '500.00',
        'closing_balance': '1200.00',
      }));

      expect(parse.rows, hasLength(3));
      expect(parse.problems, isEmpty);
    });

    test('and a line missing from the END is caught, which the chain cannot',
        () {
      // The failure this exists for. Drop the last line and every
      // remaining pair of balances still agrees perfectly -- there is
      // nothing left for a line-to-line walk to notice.
      final short = threeLines()..removeLast();
      final parse = scannedStatement(read(short, statement: {
        'opening_balance': '500.00',
        'closing_balance': '1200.00',
      }));

      expect(parse.rows, hasLength(2));
      expect(parse.problems, hasLength(1));
      expect(parse.problems.single, contains('500.00'));
      expect(parse.problems.single, contains('1200.00'));
      // What it reached, and how far out it is.
      expect(parse.problems.single, contains('1250.00'));
      expect(parse.problems.single, contains('50.00'));
      expect(parse.problems.single, contains('nothing has been changed'));
    });

    test('a sen of rounding is not a missing line', () {
      // A page of two-decimal money can legitimately drift a sen. A
      // complaint on every statement teaches people to ignore all of
      // them.
      final parse = scannedStatement(read(threeLines(), statement: {
        'opening_balance': '500.00',
        'closing_balance': '1200.01',
      }));

      expect(parse.problems, isEmpty);
    });

    test('but two sen is', () {
      final parse = scannedStatement(read(threeLines(), statement: {
        'opening_balance': '500.00',
        'closing_balance': '1200.02',
      }));

      expect(parse.problems, hasLength(1));
    });

    test('a statement that prints no balances is not complained about', () {
      // Every reading taken before the header was asked for, and every
      // document that genuinely does not print one. Absence is not
      // disagreement.
      final parse = scannedStatement(read(threeLines()));

      expect(parse.rows, hasLength(3));
      expect(parse.problems, isEmpty);
    });

    test('nor is one that prints only an opening balance', () {
      final parse = scannedStatement(read(threeLines(), statement: {
        'opening_balance': '500.00',
      }));

      expect(parse.problems, isEmpty);
    });

    test('and the balances are read the way statements print them', () {
      // `1,200.00 CR` and `(50.00)` are the same conventions the line
      // amounts use, and the header has to read them the same way or a
      // statement complains about arithmetic that is correct.
      final parse = scannedStatement(read(threeLines(), statement: {
        'opening_balance': 'RM 500.00',
        'closing_balance': '1,200.00 CR',
      }));

      expect(parse.problems, isEmpty);
    });
  });

  group('the period places the lines', () {
    List<Map<String, String>> dayAndMonth() => [
          {'transaction_date': '01 Oct', 'description': 'A', 'amount': '10.00'},
          {'transaction_date': '03 Oct', 'description': 'B', 'amount': '-4.00'},
        ];

    test('period_end is an anchor where the lines carry no year', () {
      final parse = scannedStatement(read(dayAndMonth(), statement: {
        'period_end': '31/10/2025',
      }));

      expect(parse.rows, hasLength(2));
      expect(parse.rows.first.date, DateTime(2025, 10, 1));
      expect(parse.rows.last.date, DateTime(2025, 10, 3));
    });

    test('period_start serves when only it was read', () {
      final parse = scannedStatement(read(dayAndMonth(), statement: {
        'period_start': '01/10/2025',
      }));

      expect(parse.rows.first.date, DateTime(2025, 10, 1));
    });

    test('and the file OUTRANKS it, as it outranks document_date', () {
      // One was extracted from the page, the other was answered by a
      // model. The rule does not change because the answer moved into a
      // different field.
      final parse = scannedStatement(
        read(dayAndMonth(), statement: {'period_end': '31/10/2024'}),
        period: (
          date: DateTime(2025, 10, 31),
          evidence: 'Statement Date 31/10/2025',
        ),
      );

      expect(parse.rows.first.date.year, 2025);
    });
  });

  /// The number over the problem list, which has been wrong twice.
  ///
  /// It used to be `problems.length`, which was right while every
  /// problem was one line. Then one message was made to cover
  /// fifty-five undated lines — the right change, because fifty-five
  /// copies of one sentence bury the cause — and the heading went on
  /// counting messages. Fifty-five discarded lines announced themselves
  /// as "1 could not be".
  ///
  /// A document-level problem is the same mistake pointing the other
  /// way: a statement that does not foot has a problem with the
  /// STATEMENT, not with a line, and must not inflate a line count.
  group('how many lines could not be read', () {
    test('is one per line where each line failed on its own', () {
      final parse = scannedStatement(read([
        {'transaction_date': '01/08/2026', 'description': 'A'},
        {'transaction_date': '02/08/2026', 'description': 'B'},
        {'transaction_date': '03/08/2026', 'amount': '10.00'},
      ]));

      expect(parse.rows, hasLength(1));
      expect(parse.unreadable, 2);
      expect(parse.problems, hasLength(2));
    });

    test('and counts LINES, not messages, when one message covers many', () {
      // Three lines print a day and a month with no year and nothing
      // anchors them. One sentence, three lines lost.
      final parse = scannedStatement(read([
        {'transaction_date': '01 Oct', 'description': 'A', 'amount': '1.00'},
        {'transaction_date': '02 Oct', 'description': 'B', 'amount': '2.00'},
        {'transaction_date': '03 Oct', 'description': 'C', 'amount': '3.00'},
      ]));

      expect(parse.rows, isEmpty);
      expect(parse.problems, hasLength(1));
      expect(parse.unreadable, 3);
    });

    test('and a statement that does not foot costs no lines at all', () {
      // Every line read perfectly. The problem is with the document.
      final parse = scannedStatement(read(threeLines(), statement: {
        'opening_balance': '500.00',
        'closing_balance': '9999.00',
      }));

      expect(parse.rows, hasLength(3));
      expect(parse.problems, hasLength(1));
      expect(parse.unreadable, 0);
    });
  });

  _accountCheck();

  group('the reading carries the header through', () {
    test('a statement object arrives as strings, like fields', () {
      final r = OcrExtraction.fromJson({
        'rows': const [],
        'statement': {
          'period_end': '31/10/2025',
          'account_number_tail': '4001',
          'institution': 'Test Bank',
          'opening_balance': null,
        },
      });

      expect(r.statement['period_end'], '31/10/2025');
      expect(r.statement['account_number_tail'], '4001');
      expect(r.statement['institution'], 'Test Bank');
      // Nulls are dropped, as everywhere else, so "not on the page"
      // arrives as an absent key rather than an empty string.
      expect(r.statement.containsKey('opening_balance'), isFalse);
    });

    test('and survives a round trip through toJson', () {
      // The scan row is written from this, and a header that does not
      // survive being logged is a header nobody can check afterwards.
      final r = OcrExtraction.fromJson({
        'rows': const [],
        'statement': {'institution': 'Test Bank'},
      });

      expect(r.toJson()['statement'], {'institution': 'Test Bank'});
    });

    test('a document with no header at all is not a failure', () {
      final r = OcrExtraction.fromJson({'rows': const []});

      expect(r.statement, isEmpty);
      expect(r.toJson().containsKey('statement'), isFalse);
    });
  });
}

/// Is this even the right account?
///
/// The reader is asked for FOUR CHARACTERS of the account number and
/// never the whole thing — enough to say "this may not be the right
/// account", not enough to be worth leaking. That privacy choice
/// decides the strength of the answer too: four digits can collide, so
/// a mismatch is a NOTICE and not a refusal.
///
/// And a second reason it is a notice. Somebody may be filing a
/// statement from an account that was renumbered, or an old one from
/// before a migration, and its lines are still perfectly importable.
/// Refusing would make this system wrong about a document the person
/// holding it knows more about than we do.
void _accountCheck() {
  group('the statement against the account it is going into', () {
    test('four digits are taken off both sides, punctuation and all', () {
      // A statement prints `**** 4001`; the account was typed in as
      // `3900-0007-994`. Comparing the strings compares the hyphens.
      expect(accountTail('**** 4001'), '4001');
      expect(accountTail('3900-0007-994'), '7994');
      expect(accountTail('8881062574767'), '4767');
      expect(accountTail('3900 0007 994'), '7994');
    });

    test('and nothing is taken from something too short to compare', () {
      expect(accountTail('123'), isNull);
      expect(accountTail(''), isNull);
      expect(accountTail(null), isNull);
      expect(accountTail('A/C'), isNull);
    });

    test('agreement is silent', () {
      expect(
        accountMismatch(statementTail: '4001', accountNumber: '1234-4001'),
        isNull,
      );
    });

    test('disagreement says both, so it can be checked against the page', () {
      final said = accountMismatch(
        statementTail: '4767',
        accountNumber: '3900-0007-994',
      );

      expect(said, isNotNull);
      expect(said, contains('4767'));
      expect(said, contains('7994'));
      // Not a refusal. The lines are still importable.
      expect(said, contains('will still import'));
    });

    test('an absence is not a disagreement', () {
      // No tail read, or an account recorded here without a number. A
      // warning raised whenever a field is blank is a warning people
      // learn to scroll past.
      expect(
        accountMismatch(statementTail: null, accountNumber: '1234-5678'),
        isNull,
      );
      expect(
        accountMismatch(statementTail: '4001', accountNumber: null),
        isNull,
      );
      expect(accountMismatch(statementTail: '12', accountNumber: '1234'),
          isNull);
    });

    test('and it reaches the parse as a notice, not a problem', () {
      final parse = scannedStatement(
        OcrExtraction.fromJson({
          'rows': [
            {
              'transaction_date': '01/08/2026',
              'description': 'A',
              'amount': '10.00',
            },
          ],
          'statement': {'account_number_tail': '9999'},
        }),
        intoAccountNumber: '1234-4001',
      );

      expect(parse.rows, hasLength(1));
      expect(parse.problems, isEmpty);
      expect(parse.unreadable, 0);
      expect(parse.notices.where((n) => n.contains('9999')), hasLength(1));
    });
  });
}
