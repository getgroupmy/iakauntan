import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/features/banking/statement_import.dart';

/// MT940, which is what a Malaysian bank gives a corporate account and
/// what the CSV parser could not read at all.
///
/// A SWIFT standard rather than a local convention, which is why this
/// one can be written from the specification: `:61:` is a statement
/// line and `:86:` is what it says, everywhere in the world.
///
/// Three things here are the ones a quick implementation gets wrong,
/// and each has its own group:
///
///   * the decimal separator is a comma, always;
///   * `RD` and `RC` are reversals and the mark is two characters, so
///     reading only the first sends every reversal the wrong way;
///   * the entry date and the funds code are both optional, so a
///     single regular expression across the front of the line reads one
///     bank's statements and not another's.
void main() {
  // A statement with one credit and one debit, wrapped the way a real
  // file wraps, with a description broken across two lines.
  const sample = '''
:20:STMT26030601
:25:MBB/514166012345
:28C:00067/001
:60F:C260305MYR15000,00
:61:2603060306C1234,56NTRFINV-2026-0041//MB2603061234
:86:INCOMING TRANSFER
SYARIKAT MAJU SDN BHD INV-2026-0041
:61:2603060306D2500,00NCHGNONREF//MB2603069999
:86:MONTHLY SERVICE CHARGE
:62F:C260306MYR13734,56
-''';

  group('reading a statement a bank actually sends', () {
    test('finds both lines', () {
      final parsed = parseMt940(sample);
      expect(parsed.problems, isEmpty);
      expect(parsed.rows.length, 2);
    });

    test('a credit is money in and a debit is money out', () {
      final rows = parseMt940(sample).rows;
      expect(rows[0].amount, 1234.56);
      expect(rows[1].amount, -2500.00);
    });

    test('on the value date', () {
      final rows = parseMt940(sample).rows;
      expect(rows[0].date, DateTime(2026, 3, 6));
    });

    test('with the description put back together', () {
      // The file wraps at eighty characters. A description broken
      // across three lines is one description, and importing the first
      // line of it loses the customer's name.
      expect(
        parseMt940(sample).rows[0].description,
        'INCOMING TRANSFER SYARIKAT MAJU SDN BHD INV-2026-0041',
      );
    });

    test('and the reference a person would recognise', () {
      // The customer reference, not the bank's own after the `//`.
      expect(parseMt940(sample).rows[0].reference, 'INV-2026-0041');
    });

    test('NONREF is not a reference', () {
      // SWIFT's way of writing "there isn't one". Showing it to
      // somebody reconciling is worse than showing nothing.
      expect(parseMt940(sample).rows[1].reference, isNull);
    });
  });

  group('the decimal separator is a comma', () {
    test('and 1234,56 is one thousand two hundred and thirty-four', () {
      final rows = parseMt940(
        ':61:260306C1234,56NTRFX\n:86:X',
      ).rows;
      expect(rows.single.amount, 1234.56);
    });

    test('a whole number still carries it', () {
      final rows = parseMt940(':61:260306C2500,00NTRFX\n:86:X').rows;
      expect(rows.single.amount, 2500.0);
    });

    test('and two commas is a broken line, not a thousands separator', () {
      // Guessing would turn 1,234,56 into something plausible and
      // wrong. It is reported instead.
      final parsed = parseMt940(':61:260306C1,234,56NTRFX\n:86:X');
      expect(parsed.rows, isEmpty);
      expect(parsed.problems, isNotEmpty);
    });
  });

  group('a reversal goes the other way', () {
    test('RD is the reversal of a debit, so the money comes back', () {
      final rows = parseMt940(':61:260306RD500,00NTRFX\n:86:X').rows;
      expect(
        rows.single.amount,
        500.0,
        reason: 'reading only the first character makes this -500, and a '
            'reversal that goes the wrong way nets to double the error',
      );
    });

    test('and RC is the reversal of a credit', () {
      final rows = parseMt940(':61:260306RC500,00NTRFX\n:86:X').rows;
      expect(rows.single.amount, -500.0);
    });

    test('while a plain D is still money out', () {
      final rows = parseMt940(':61:260306D500,00NTRFX\n:86:X').rows;
      expect(rows.single.amount, -500.0);
    });
  });

  group('the optional fields', () {
    test('a line with no entry date reads the same', () {
      // Value date only: six digits then the mark.
      final rows = parseMt940(':61:260306C100,00NTRFX\n:86:X').rows;
      expect(rows.single.amount, 100.0);
      expect(rows.single.date, DateTime(2026, 3, 6));
    });

    test('and one with an entry date does not read it as the value date', () {
      // 260306 value, 0307 entry. The value date is what the ledger
      // reconciles against; taking the entry date would put the line on
      // the wrong day, which is a difference nobody can place.
      final rows = parseMt940(':61:2603060307C100,00NTRFX\n:86:X').rows;
      expect(rows.single.date, DateTime(2026, 3, 6));
    });

    test('a funds code between the mark and the amount is skipped', () {
      // `:61:260306CF100,00...` — the F is a funds code, not part of
      // the amount.
      final rows = parseMt940(':61:260306CF100,00NTRFX\n:86:X').rows;
      expect(rows.single.amount, 100.0);
    });

    test('and a line with no :86: after it is still a transaction', () {
      // Two lines, and only the second has a description. Dropping the
      // first would lose a real payment.
      final rows = parseMt940(
        ':61:260306C100,00NTRFA\n'
        ':61:260307C200,00NTRFB\n'
        ':86:SECOND ONE\n'
        ':62F:C260307MYR300,00',
      ).rows;
      expect(rows.length, 2);
      expect(rows[0].amount, 100.0);
      expect(rows[0].description, isNull);
      expect(rows[1].description, 'SECOND ONE');
    });
  });

  group('picking the format', () {
    test('an MT940 is read as one even though it is pasted as text', () {
      // Detected on `:61:`, not on a file extension: the extension is
      // .txt or .sta or .940 depending on the bank and is missing
      // entirely from a paste.
      final parsed = parseStatement(sample);
      expect(parsed.rows.length, 2);
      expect(parsed.rows[0].amount, 1234.56);
    });

    test('and a CSV is still read as a CSV', () {
      final parsed = parseStatement(
        'Date,Description,Amount\n06/03/2026,Transfer in,1234.56',
      );
      expect(parsed.rows.length, 1);
      expect(parsed.rows.single.amount, 1234.56);
      expect(parsed.rows.single.description, 'Transfer in');
    });

    test('a CSV with a "reference" column is not mistaken for MT940', () {
      // The detector looks for `:61:` at the start of a line. A CSV
      // whose cells contain colons must not trip it.
      final parsed = parseStatement(
        'Date,Description,Reference,Amount\n'
        '06/03/2026,Paid at 09:61:00,REF:61:X,-50.00',
      );
      expect(parsed.rows.length, 1);
      expect(parsed.rows.single.amount, -50.00);
    });
  });

  group('what it refuses to guess', () {
    test('a file with no statement lines says so', () {
      final parsed = parseMt940(':20:STMT1\n:25:ACC\n:62F:C260306MYR0,00');
      expect(parsed.rows, isEmpty);
      expect(parsed.problems.single, contains(':61:'));
    });

    test('an unreadable line is reported with its number, not dropped', () {
      // A statement that imports three of four lines without saying so
      // reconciles to the wrong number.
      final parsed = parseMt940(
        ':61:260306C100,00NTRFA\n'
        ':86:GOOD\n'
        ':61:NOT A STATEMENT LINE\n'
        ':86:BAD',
      );
      expect(parsed.rows.length, 1);
      expect(parsed.problems.length, 1);
      expect(parsed.problems.single, contains('Line 3'));
    });

    test('and an impossible date is one of those', () {
      // 31 February. Letting DateTime roll it over to 3 March would
      // reconcile against the wrong day.
      final parsed = parseMt940(':61:260231C100,00NTRFA\n:86:X');
      expect(parsed.rows, isEmpty);
      expect(parsed.problems, isNotEmpty);
    });
  });
}
