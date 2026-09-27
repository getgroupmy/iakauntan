// A credit card's header, which says four things at once.
//
// `statement_period_test.dart` covers a deposit statement's header: one
// date, or one span, and a great deal of noise around it. A card's is a
// different document. It prints a statement date AND a payment due date
// side by side, and the due date is a real date three weeks later --
// on a 20 August statement it reads 10 September, which is the NEXT
// period.
//
// The rule that read every deposit statement correctly was "take the
// later date", because on a span later means the end of it. Measured
// against five realistic card layouts before any of this was written,
// that rule returned the DUE date on two of them, filing an August
// statement into September. Both are below, and both would fail again
// if the cut or the column rule were removed.
import 'package:flutter_test/flutter_test.dart';
import 'package:iakauntan/src/features/banking/statement_import.dart';

void main() {
  group('a card prints its due date beside its statement date', () {
    test('both on one line, and only the first is ours', () {
      final r = statementPeriodFromText('''
XYZ BANK BERHAD
Statement Date : 20 AUG 2026        Payment Due Date : 10 SEP 2026
Card Number : 4111 XXXX XXXX 7788
''');
      expect(r?.date, DateTime(2026, 8, 20));
    });

    test('labels across, values under, and ours is the first column', () {
      final r = statementPeriodFromText('''
XYZ BANK BERHAD
Statement Date   Payment Due Date   Minimum Payment Due
20/08/2026       10/09/2026         RM 250.00
''');
      expect(r?.date, DateTime(2026, 8, 20));
    });

    test('a block of labels then a block of values', () {
      final r = statementPeriodFromText('''
XYZ BANK BERHAD
STATEMENT DATE / TARIKH PENYATA
PAYMENT DUE DATE / TARIKH AKHIR PEMBAYARAN
: 20/08/2026
: 10/09/2026
''');
      expect(r?.date, DateTime(2026, 8, 20));
    });

    test('in Malay, on separate lines', () {
      final r = statementPeriodFromText('''
XYZ BANK BERHAD
Tarikh Penyata : 20/08/2026
Tarikh Akhir Pembayaran : 10/09/2026
''');
      expect(r?.date, DateTime(2026, 8, 20));
    });

    test('the due date alone is not a statement date', () {
      // Nothing here says when the statement is for. A card whose
      // statement date did not extract must come back null and be
      // told about, not be filed on the day the money is owed.
      final r = statementPeriodFromText('''
XYZ BANK BERHAD
Payment Due Date : 10 SEP 2026
Minimum Payment Due : RM 250.00
''');
      expect(r, isNull);
    });
  });

  group('and the money beside it is not a date', () {
    test('a credit limit does not end up read as one', () {
      final r = statementPeriodFromText('''
Statement Date 20/08/2026   Credit Limit 30,000.00
''');
      expect(r?.date, DateTime(2026, 8, 20));
    });

    test('a minimum payment printed as a figure with slashes', () {
      // `10/09/2026` in a Minimum Payment column would be nonsense, but
      // a reference or an instalment count printed as `03/12` is not --
      // and it reads as a date. The cut is what keeps it out.
      final r = statementPeriodFromText('''
Statement Date 20/08/2026   Minimum Payment 03/12 instalments
''');
      expect(r?.date, DateTime(2026, 8, 20));
    });
  });

  group('a deposit statement reads exactly as it did', () {
    test('AmBank: a span three lines under its label', () {
      final r = statementPeriodFromText('''
AMBANK
ACCOUNT NO. / NO. AKAUN
STATEMENT DATE / TARIKH PENYATA
: 8881062574767
: 01/12/2025 - 31/12/2025
''');
      // The END of the span. Two phrases naming one field in two
      // languages is a bilingual header, not two columns -- and if it
      // were counted as two, this would come back 01/12.
      expect(r?.date, DateTime(2025, 12, 31));
    });

    test('a bare period label, as all 120 corpus fixtures print it', () {
      final r = statementPeriodFromText(
          'Account: **** 4001 | Period: 01/08/2026-31/08/2026 | Currency: MYR');
      expect(r?.date, DateTime(2026, 8, 31));
    });
  });
}
