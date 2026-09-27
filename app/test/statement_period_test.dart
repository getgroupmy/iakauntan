import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/data/ocr_repository.dart';
import 'package:iakauntan/src/features/banking/statement_import.dart';
import 'package:iakauntan/src/features/shared/scan_runner.dart';

/// The statement's own date, taken off the file instead of asked for.
///
/// ## What went wrong, on real paper
///
/// Two RHB statements, 43 and 59 rows, read faultlessly by a vision
/// model: right target, brought-forward and carried-forward rows in the
/// proper shape, signed amounts, running balances, multi-line
/// narrations preserved. Every line printed `01 Oct` or `23 Jan` — a
/// day and a month — and `document_date` came back NULL.
///
/// `resolveStatementYear` then has no anchor. It refuses to guess, by
/// design, because a statement photographed in January whose lines are
/// last December would otherwise be filed into a financial year that
/// may already be closed. So a hundred and two perfect lines were
/// thrown away for want of one field.
///
/// And RHB exports a TEXT PDF. The period is printed on page one as
/// selectable text, and this repository has had `pdf.js` vendored under
/// `web/pdfjs/` the whole time. The year was never missing. It was
/// never looked at.
///
/// ## The rule these assertions are really defending
///
/// A model is ASKED and may decline. A text layer is READ. Where the
/// evidence is printed, deterministic and already in hand, it outranks
/// the answer to a question — which is the single most important thing
/// in the handover this came from, and the reason `period` beats
/// `document_date` below rather than filling in behind it.
///
/// The other half is restraint. A statement's text layer is thick with
/// dates: a print date, a payment due date, an address with a postcode
/// that reads like a year, and every transaction line. A reader that
/// takes the first thing shaped like a date would place the whole
/// statement on the strength of a due date — so most of what follows is
/// about what this must REFUSE to read.
void main() {
  group('a labelled statement date', () {
    test('is read in English, day first', () {
      final found = statementPeriodFromText('''
RHB BANK BERHAD
CURRENT ACCOUNT STATEMENT
Account No : 2141 0400 0123 45
Statement Date : 31/10/2025
''');

      expect(found, isNotNull);
      expect(found!.date, DateTime(2025, 10, 31));
      // The line itself, so the notice can quote the page rather than
      // asking somebody to take its word for it.
      expect(found.evidence, contains('Statement Date'));
    });

    test('and in Malay, which is how half of them print it', () {
      final found = statementPeriodFromText(
        'PENYATA AKAUN SEMASA\nTarikh Penyata 31 Oktober 2025\n',
      );

      expect(found?.date, DateTime(2025, 10, 31));
    });

    test('a period gives its END, not its start', () {
      // The statement is named by where it closes, and the closing
      // balance is what the chain has to reach.
      final found = statementPeriodFromText(
        'Statement Period 01/10/2025 - 31/10/2025',
      );

      expect(found?.date, DateTime(2025, 10, 31));
    });

    test('and a label in one table cell finds the date in the next', () {
      // `pdf.js` emits a two-cell row as two lines. A label plainly
      // there, with the date one line down, is not a document without
      // a statement date.
      final found = statementPeriodFromText(
        'Tarikh Penyata\n30/09/2025\n',
      );

      expect(found?.date, DateTime(2025, 9, 30));
    });

    test('is preferred over a payment due date sitting beside it', () {
      // A credit-card statement prints both, the due date LATER, and
      // taking the wrong one files every line three weeks out.
      final found = statementPeriodFromText('''
Payment Due Date 20/11/2025
Statement Date 31/10/2025
Minimum Payment RM 50.00
''');

      expect(found?.date, DateTime(2025, 10, 31));
    });
  });

  group('what it refuses to read', () {
    test('a page full of transaction dates and no label at all', () {
      // The whole point. These are the lines, not the header, and
      // placing a statement from its first transaction is a guess
      // wearing a date's clothes.
      final found = statementPeriodFromText('''
01/10 TRANSFER TO LIM HARDWARE 1,250.00 980,124.85
03/10 DUITNOW QR 45.90 980,078.95
05/10 IBG CREDIT 12,000.00 992,078.95
''');

      expect(found, isNull);
    });

    test('a header naming two different months', () {
      // Two plausible readings is a null and a sentence. Never infer a
      // year when two interpretations remain open.
      final found = statementPeriodFromText(
        'STATEMENT\nOctober 2025\nBrought forward from September 2025\n',
      );

      expect(found, isNull);
    });

    test('a bare numeric 10/2025, which is also the middle of a date', () {
      final found = statementPeriodFromText('PENYATA 10/2025');

      expect(found, isNull);
    });

    test('a month and year past the header, where the lines live', () {
      // Forty lines in, this is a narration. A description reading
      // "RENTAL MAY 2024" must not out-vote the header.
      final padding = List.filled(60, 'DUITNOW TRANSFER 100.00').join('\n');
      final found = statementPeriodFromText('$padding\nRENTAL MAY 2024\n');

      expect(found, isNull);
    });

    test('an impossible date, rather than rolling it over', () {
      // 31 February becoming 3 March would anchor the statement to a
      // day nobody printed.
      expect(statementPeriodFromText('Statement Date 31/02/2026'), isNull);
    });

    test('and nothing at all', () {
      expect(statementPeriodFromText(''), isNull);
      expect(statementPeriodFromText('   \n\n  '), isNull);
    });
  });

  group('the header may name its own month', () {
    test('when exactly one month and year appears and nothing contradicts', () {
      final found = statementPeriodFromText('''
MAYBANK ISLAMIC BERHAD
PENYATA BAGI OKTOBER 2025
Akaun : 5123 4567 8901
''');

      // The last day of it, because that is where a period ends and
      // what every line on it is nearest to.
      expect(found?.date, DateTime(2025, 10, 31));
    });

    test('and a four-digit number that is not a year does not make one', () {
      // "MAR 1234" is a reference, not March of the year 1234.
      expect(statementPeriodFromText('REF MAR 1234'), isNull);
    });
  });

  /// Day-first, without exception.
  ///
  /// `05/03/2026` is the fifth of March in Malaysia and the third of
  /// May in an American layout, and there is nothing in the string to
  /// tell them apart. The rule is the local one, applied always rather
  /// than sniffed at per document — a sniffing parser gets it right on
  /// the statements where the day exceeds twelve and silently wrong on
  /// the twelve days a month where it does not.
  group('never MM/DD/YYYY', () {
    test('the fifth of March, not the third of May', () {
      final found = statementPeriodFromText('Statement Date 05/03/2026');

      expect(found?.date, DateTime(2026, 3, 5));
    });
  });

  /// Five of the twelve Malay months do not share three letters with
  /// their English name. `_monthNumber` knew none of them, so a
  /// Bahasa Melayu statement came back as every line unreadable — over
  /// the language it was printed in, on statements Maybank, CIMB and
  /// Bank Islam all issue.
  group('a month printed in Malay', () {
    void reads(String raw, int day, int month) {
      final p = parsePartialStatementDate(raw);
      expect(p, isNotNull, reason: '"$raw" read as nothing');
      expect(p!.day, day);
      expect(p.month, month);
    }

    test('the five that differ', () {
      reads('01 MAC', 1, 3);
      reads('05 MEI', 5, 5);
      reads('03 OGOS', 3, 8);
      reads('10 OKT', 10, 10);
      reads('17 DIS', 17, 12);
    });

    test('the long forms too', () {
      reads('17 Disember', 17, 12);
      reads('03 Ogos', 3, 8);
    });

    test('and English still reads the way it did', () {
      reads('03 SEP', 3, 9);
      reads('3-Sep', 3, 9);
      reads('25 December', 25, 12);
    });

    test('a word that is not a month is still nothing', () {
      // The failure a map makes easy: a lookup that returns a number
      // for anything three letters long would turn "TRANSFER" into a
      // date.
      expect(parsePartialStatementDate('03 TRANSFER'), isNull);
      expect(parsePartialStatementDate('03 XYZ'), isNull);
    });
  });

  /// The line above the notices, which was false in production.
  ///
  /// It read "$n lines were corrected against the running balance" —
  /// written when a sign repair was the only notice there was. A year
  /// taken off the statement header is not an arithmetic correction and
  /// was about to be announced as one, and the count was a count of
  /// NOTICES wearing the word "lines": the new notice covers fifty-five
  /// lines in one sentence and would have called itself one.
  /// Three real Malaysian statements, and what each one broke.
  ///
  /// The layouts below are copied from the files themselves. The
  /// account numbers, names and addresses are NOT — those are
  /// somebody's actual banking details and do not belong in a
  /// repository. What is preserved is the SHAPE, which is the only
  /// part that was ever the problem.
  ///
  /// One caveat, stated rather than glossed: these were extracted with
  /// a different PDF library than the one that runs in the browser.
  /// `pdf.js` joins its text items with a space unless the item carries
  /// `hasEOL`, so it will not weld tokens together in quite the same
  /// places. Both spellings are asserted where it matters, because the
  /// parser must not depend on which of them it is handed.
  group('the statements this actually failed on', () {
    test('AmBank prints its labels and its values in separate blocks', () {
      // Every label, then every value. The statement date's value is
      // three lines below its label, behind the account number -- so a
      // parser that tries only the next line finds an account number,
      // no date, and gives up on a period printed in full.
      final found = statementPeriodFromText(
        'ACCOUNT NO. / NO. AKAUN\n'
        'STATEMENT DATE / TARIKH PENYATA\n'
        ': 1234567890123\n'
        ': 01/12/2025 - 31/12/2025\n'
        'CURRENCY / MATA WANG\n'
        'PAGE / MUKA SURAT\n'
        ': MYR\n'
        ': 1 of 3\n',
      );

      // The END of the period. A statement is named by where it closes.
      expect(found?.date, DateTime(2025, 12, 31));
    });

    test('and Hong Leong welds the address onto the period end', () {
      // `08/01/25PERSIARAN` -- the next cell of the table run onto the
      // closing date with no space. A trailing word boundary cannot
      // match between `5` and `P`, so the closing date was invisible
      // and the OPENING one was taken instead: a statement anchored to
      // the wrong end of itself.
      final found = statementPeriodFromText(
        'Page No  / No Mukasurat : 1 of 9\n'
        'Statement Period  / : 09/12/24 - 08/01/25PERSIARAN SG LONG 2\n'
        'Tempoh PenyataanBANDAR SG LONG\n',
      );

      expect(found?.date, DateTime(2025, 1, 8));
    });

    test('and the same header spaced out the way pdf.js would give it', () {
      final found = statementPeriodFromText(
        'Statement Period  / : 09/12/24 - 08/01/25 PERSIARAN SG LONG 2',
      );

      expect(found?.date, DateTime(2025, 1, 8));
    });

    test('a year still cannot run on into a reference number', () {
      // Dropping the boundary must not let the year eat digits. That
      // is what the boundary was really guarding; `(?!\d)` replaced it,
      // and letters are all that got let through.
      expect(statementPeriodFromText('Statement Date 09/12/241234'), isNull);
    });
  });

  /// UOB, which I was wrong about.
  ///
  /// Earlier in this work I told the user UOB's statements were
  /// "largely inline images" and would stay a vision-model job. That
  /// was drawn from page one of ONE file, which is a page of legal
  /// boilerplate with the table headings rendered — and it was wrong
  /// about the document. Four more UOB statements have a full text
  /// layer: around eight thousand characters in the first three pages,
  /// every transaction in it.
  ///
  /// It is worth the correction being a test rather than a note,
  /// because the shape UOB prints is one no other bank here does:
  ///
  ///     Basic Savings Acct* A/C Number: 1-2-3 RM 01 FEB 2021 To 28 FEB 2021
  ///
  /// The period is on the same line as the account number, with no
  /// label anywhere — not `Statement Period`, not `Tarikh Penyata`,
  /// nothing. What resolves it is the unlabelled path: one month and
  /// one year in the header region and nothing contradicting them.
  ///
  /// The account number and name are redacted; the layout is not.
  group('UOB prints its period with no label at all', () {
    ({DateTime date, String evidence})? read(String month, String year,
        String lastDay) =>
        statementPeriodFromText(
          'Aktiviti Akaun Anda / Account Activities for Your\n'
          'Basic Savings Acct* A/C Number: 1-2-3 RM '
          '01 $month $year To $lastDay $month $year\n'
          'Tarikh\nTransaksi\nTrans Date\n'
          'Deskripsi Transaksi\nTransaction Description\n'
          'Keluar\nWithdrawal\nSimpanan\nDeposit\nBaki\nBalance\n'
          'BALANCE B/F 1,112.38\n',
        );

    test('and the period still comes out, at its END', () {
      expect(read('FEB', '2021', '28')?.date, DateTime(2021, 2, 28));
      expect(read('MAY', '2023', '31')?.date, DateTime(2023, 5, 31));
      expect(read('JUN', '2023', '30')?.date, DateTime(2023, 6, 30));
      expect(read('MAR', '2023', '31')?.date, DateTime(2023, 3, 31));
    });

    test('its lines print a day and a month, which place against that', () {
      // `01 FEB 01 FEB DuitNow/Instant Trf` — a transaction date and a
      // value date, neither carrying a year.
      final p = parsePartialStatementDate('01 FEB');
      expect(p, isNotNull);
      expect(p!.day, 1);
      expect(p.month, 2);
    });

    test('and a second month in the header would refuse, not guess', () {
      // The guard that makes the unlabelled path safe. UOB's header
      // names one month twice; a header naming two is two plausible
      // readings and gets a null.
      final found = statementPeriodFromText(
        'Basic Savings Acct* A/C Number: 1-2-3 RM '
        '01 FEB 2021 To 28 FEB 2021\n'
        'Brought forward from JAN 2021\n',
      );

      expect(found, isNull);
    });
  });

  /// `01Jan` -- the reported one, with a screenshot.
  ///
  /// "0 lines read, 27 could not be", then five copies of
  /// `no date could be read from "01Jan"`. A complaint about a date
  /// that is perfectly legible, on every line of the statement, raised
  /// because the separator the parser insisted on was not printed.
  ///
  /// AmBank jams them: `07Dec`, `26Dec`, `01Jan`, `13Jan`.
  group('a day and a month with nothing between them', () {
    void reads(String raw, int day, int month) {
      final p = parsePartialStatementDate(raw);
      expect(p, isNotNull, reason: '"$raw" read as nothing');
      expect(p!.day, day);
      expect(p.month, month);
    }

    test('the reported statement, line by line', () {
      reads('01Jan', 1, 1);
      reads('13Jan', 13, 1);
      reads('14Jan', 14, 1);
      reads('28Jan', 28, 1);
      reads('07Dec', 7, 12);
      reads('26Dec', 26, 12);
    });

    test('and jammed Malay too, since both are printed that way', () {
      reads('03Ogos', 3, 8);
      reads('17Dis', 17, 12);
    });

    test('the spaced and hyphenated forms still read', () {
      // Most banks do print a separator. Making it optional must not
      // cost the layouts that already worked.
      reads('03 SEP', 3, 9);
      reads('3-Sep', 3, 9);
    });

    test('an ordinal is not a date', () {
      // The risk a relaxed separator creates: `1ST` and `3RD` are two
      // letters, which is why `_monthNumber` insists on three.
      expect(parsePartialStatementDate('1ST'), isNull);
      expect(parsePartialStatementDate('3RD'), isNull);
      expect(parsePartialStatementDate('22ND'), isNull);
    });

    test('and two letters is never a month', () {
      // The guard that stops `1ST` being a date is the three-letter
      // minimum, and with the separator now optional it is the only
      // thing standing between a reference and a transaction date.
      //
      // EQUIVALENT MUTANT, written down here rather than left for
      // somebody to hunt: relaxing `_monthNumber`'s own
      // `if (s.length < 3) return null` to `< 2` cannot be caught. Every
      // caller reaches it through a regex that already demands
      // `[A-Za-z]{3,}` -- `parsePartialStatementDate`,
      // `parseStatementDate`, `_datesIn` and the header month-year scan
      // are all spelled that way -- so a two-letter name never arrives
      // at the guard at all. The assertions below still say what the
      // intent is, and they would catch a regex relaxed to `{2,}`;
      // they simply cannot catch the guard being loosened underneath
      // one that is stricter.
      expect(parsePartialStatementDate('03DE'), isNull);
      expect(parsePartialStatementDate('03JA'), isNull);
      expect(parsePartialStatementDate('03 MA'), isNull);
    });

    test('a label with no date near it does not reach the transactions', () {
      // The window must stop inside the header. Widen it and the label
      // finds the first TRANSACTION date instead, which anchors the
      // whole statement to its own first entry -- a guess wearing a
      // date's clothes, and the exact failure all of this refuses.
      final found = statementPeriodFromText(
        'Statement Period\n'
        'Account 1234567\n'
        'Branch KUALA LUMPUR MAIN BRANCH\n'
        'Tel No 03-2164 2525\n'
        'Page No 1 of 9\n'
        '09-12-2024 FPX Payment fr CA via Internet 20,000.00\n'
        '10-12-2024 Instant Transfer 37,222.88\n',
      );

      expect(found, isNull);
    });
    test('and neither is a word that merely starts like one', () {
      expect(parsePartialStatementDate('03DECLINED'), isNull);
      expect(parsePartialStatementDate('12MARGIN'), isNull);
    });
  });

  _platformSeam();

  group('the heading above the notices', () {
    test('claims no cause, because there is more than one', () {
      for (final n in [1, 2, 7]) {
        expect(noticesHeading(n), isNot(contains('running balance')));
        expect(noticesHeading(n), isNot(contains('corrected')));
      }
    });

    test('and counts no lines, because it cannot know them', () {
      // "1 line" over a notice about fifty-five of them. The count of
      // notices is not the count of lines and has not been since a
      // notice was allowed to cover more than one.
      expect(noticesHeading(1), isNot(contains('line')));
      expect(noticesHeading(3), isNot(contains('lines')));
    });

    test('reads as English at one and at many', () {
      expect(noticesHeading(1), 'One thing worth knowing before you import');
      expect(noticesHeading(3), '3 things worth knowing before you import');
    });
  });

  group('the reading and the file together', () {
    OcrExtraction read(List<Map<String, String>> rows, {String? date}) =>
        OcrExtraction.fromJson({
          'rows': rows,
          if (date != null) 'document_date': date,
        });

    final october = (date: DateTime(2025, 10, 31), evidence: 'Statement Date 31/10/2025');

    List<Map<String, String>> rhb() => [
          {'description': 'B/F BALANCE', 'running_balance': '981,374.85'},
          {
            'transaction_date': '01 Oct',
            'description': 'TRANSFER TO LIM HARDWARE',
            'amount': '-1,250.00',
            'running_balance': '980,124.85',
          },
          {
            'transaction_date': '03 Oct',
            'description': 'IBG CREDIT',
            'amount': '12,000.00',
            'running_balance': '992,124.85',
          },
        ];

    test('places the lines the reader could not', () {
      // The reported case exactly: day-and-month lines, document_date
      // null, and the year sitting in the file's text layer all along.
      final parse = scannedStatement(read(rhb()), period: october);

      expect(parse.rows, hasLength(2));
      expect(parse.rows.first.date, DateTime(2025, 10, 1));
      expect(parse.rows.last.date, DateTime(2025, 10, 3));
      expect(parse.problems, isEmpty);
    });

    test('and says where the year came from', () {
      final parse = scannedStatement(read(rhb()), period: october);

      final notice = parse.notices.singleWhere(
        (n) => n.contains('no year'),
        orElse: () => '',
      );
      expect(notice, isNotEmpty);
      // The count, the date used, and the line it was read off — so
      // somebody can disagree with it against the page.
      expect(notice, contains('2'));
      expect(notice, contains('31/10/2025'));
      expect(notice, contains('Statement Date 31/10/2025'));
    });

    test('the file OUTRANKS what the reader said', () {
      // The model offered a year and the page printed one. The page
      // wins: one was extracted, the other was answered.
      final parse = scannedStatement(
        read(rhb(), date: '2024-10-31'),
        period: october,
      );

      expect(parse.rows.first.date.year, 2025);
    });

    test('and with neither, nothing is guessed', () {
      final parse = scannedStatement(read(rhb()));

      expect(parse.rows, isEmpty);
      expect(parse.problems, hasLength(1));
      expect(parse.problems.single, contains('2 lines print'));
      expect(parse.problems.single, contains('Nothing has been guessed'));
    });

    test('a statement whose lines carry their own year ignores the file', () {
      // Nothing to place, so nothing to say. A notice on a statement
      // that never needed one is noise, and noise is how the real ones
      // stop being read.
      final parse = scannedStatement(
        read([
          {
            'transaction_date': '03/09/2026',
            'description': 'TRANSFER',
            'amount': '-1,250.00',
          },
        ]),
        period: october,
      );

      expect(parse.rows.single.date, DateTime(2026, 9, 3));
      expect(parse.notices, isEmpty);
    });
  });
}

/// The reader that made this possible, asked what it can do here.
///
/// `pdfTextLayer` is the seam between a pure parser and a platform.
/// Under `dart:io` — which is what a `flutter test` VM is, and what a
/// phone is — `onDeviceReadsPdf` is false: ML Kit takes an image and
/// nothing else, and there is no 1.8MB of `pdf.js` on a phone to make
/// up the difference.
///
/// So what these assert is the DEGRADATION, which is the half that
/// runs everywhere. Every caller uses this to improve a reading it
/// already has, never to replace one — and a null has to mean "no text
/// here", quietly, or a phone would start refusing statements a
/// browser reads and a photograph would start failing instead of
/// scanning.
void _platformSeam() {
  group('the PDF text layer, where this machine has no engine for one', () {
    test('answers null rather than throwing', () async {
      // `readTextFromPdfBytes` under dart:io throws UnsupportedError by
      // design. If that ever reaches the importer, pressing Upload on a
      // phone stops importing statements at all.
      final pdf = Uint8List.fromList([0x25, 0x50, 0x44, 0x46, 0x2D]);

      expect(await pdfTextLayer(pdf, 'application/pdf'), isNull);
    });

    test('and null for anything that is not a PDF at all', () async {
      // A photographed statement. The commonest case there is, and it
      // must cost nothing -- no engine loaded, no exception caught.
      final jpeg = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0]);

      expect(await pdfTextLayer(jpeg, 'image/jpeg'), isNull);
      expect(await pdfTextLayer(null, 'application/pdf'), isNull);
    });
  });
}
