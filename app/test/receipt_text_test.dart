import 'package:flutter_test/flutter_test.dart';
import 'package:iakauntan/src/features/shared/receipt_text.dart';

/// The on-device reader hands back printing, not fields, so everything
/// between "JUMLAH 45.90" and a filled-in expense form happens in
/// `parseReceiptText`. There is no server to correct it and no model to
/// blame, which makes this the piece worth pinning down hardest.
///
/// The fixtures are the shapes Malaysian receipts actually come in:
/// a supermarket till roll with a savings line designed to be mistaken
/// for a total, a tax invoice with SST separated, a petrol slip with no
/// tax at all, and a Malay-language receipt.
void main() {
  group('a supermarket till roll', () {
    const text = '''
99 SPEEDMART 1234
NO 12 JALAN SS2/24
47300 PETALING JAYA
SST REG NO: W10-1808-31000123
RECEIPT NO: R-004512
DATE: 12/06/2026 18:42
--------------------------------
MILO 3IN1 1KG            21.90
GARDENIA BREAD            3.50
MAGGI CURRY 5S            6.00
--------------------------------
TOTAL SAVINGS             4.20
SUBTOTAL                 31.40
SST 8%                    2.51
TOTAL                    33.91
CASH                     50.00
CHANGE                   16.09
''';

    test('the total is the total, not the savings and not the cash', () {
      final read = parseReceiptText(text);
      // TOTAL SAVINGS sits above TOTAL and contains the word; CASH and
      // CHANGE sit below it and are larger. Both are the obvious way to
      // get this wrong.
      expect(read.totalAmount, 33.91);
      expect(read.subtotal, 31.40);
      expect(read.taxAmount, 2.51);
    });

    test('the registration number is not read as tax charged', () {
      final read = parseReceiptText(text);
      // `W10-1808-31000123` sits on a line matching the tax label and is
      // nothing but digits and dashes.
      expect(read.supplierTaxId, 'W10-1808-31000123');
      expect(read.taxAmount, 2.51);
    });

    test('day first, because this is Malaysia', () {
      expect(parseReceiptText(text).documentDate, DateTime(2026, 6, 12));
    });

    test('the supplier and the receipt number', () {
      final read = parseReceiptText(text);
      expect(read.supplierName, '99 SPEEDMART 1234');
      expect(read.documentNo, 'R-004512');
      expect(read.currency, isNull); // nothing on it says RM
    });

    test('the printed lines, and nothing below the rule', () {
      final read = parseReceiptText(text);
      expect(read.lines.map((l) => l.description), [
        'MILO 3IN1 1KG',
        'GARDENIA BREAD',
        'MAGGI CURRY 5S',
      ]);
      expect(read.lines.first.amount, 21.90);
    });

    test('it foots, so there is nothing to warn about', () {
      expect(parseReceiptText(text).note, isNull);
    });
  });

  group('a tax invoice', () {
    const text = '''
SYARIKAT MAJU JAYA SDN BHD
(Company No. 201901030189)
Lot 5, Jalan Perindustrian 3
SST No: B16-2109-22000456
TAX INVOICE NO: INV-2026-0087
Date: 30 June 2026

Description                Amount
Office supplies            RM 450.00
Delivery                    RM 30.00

Subtotal                   RM 480.00
SST @ 8%                    RM 38.40
Total Inclusive of SST     RM 518.40
''';

    test('a spelled-out month, and a company suffix for the name', () {
      final read = parseReceiptText(text);
      expect(read.documentDate, DateTime(2026, 6, 30));
      expect(read.supplierName, 'SYARIKAT MAJU JAYA SDN BHD');
      expect(read.documentNo, 'INV-2026-0087');
    });

    test('RM makes it ringgit', () {
      expect(parseReceiptText(text).currency, 'MYR');
    });

    test('"Total Inclusive of SST" is the total', () {
      final read = parseReceiptText(text);
      expect(read.totalAmount, 518.40);
      expect(read.subtotal, 480.00);
      expect(read.taxAmount, 38.40);
      expect(read.note, isNull);
    });

    test('the amount to key is the net, not the gross', () {
      // The expense form adds tax back from its own tax code, so
      // handing it 518.40 would charge the tax twice.
      expect(parseReceiptText(text).netAmount, 480.00);
    });

    test('the rate beside the tax is not mistaken for the amount', () {
      // "SST @ 8%" — the 8 is a rate and has no decimals, which is what
      // keeps it out. The figure taken is the last money on the line.
      expect(parseReceiptText(text).taxAmount, 38.40);
    });
  });

  group('a petrol slip with no tax', () {
    const text = '''
PETRON SEKSYEN 13
JLN PROFESSOR KHOO KAY KIM
14/07/26  07:15
PUMP 04  RON95
LITRES 32.50
TOTAL RM 68.25
THANK YOU
''';

    test('no tax printed means null, not zero', () {
      final read = parseReceiptText(text);
      expect(read.totalAmount, 68.25);
      // Zero would claim the slip printed a zero. It printed nothing.
      expect(read.taxAmount, isNull);
      expect(read.subtotal, isNull);
    });

    test('a two-digit year is this century', () {
      expect(parseReceiptText(text).documentDate, DateTime(2026, 7, 14));
    });

    test('with only one figure, that figure is what to key', () {
      expect(parseReceiptText(text).netAmount, 68.25);
    });

    test('a quantity without decimals is not money', () {
      // "LITRES 32.50" has decimals and would otherwise be a line item;
      // it is above the total, so it is offered as one. What must not
      // happen is "PUMP 04" or "RON95" becoming an amount.
      final read = parseReceiptText(text);
      expect(read.lines.every((l) => l.amount != 4 && l.amount != 95), isTrue);
    });
  });

  group('a receipt in Malay', () {
    const text = '''
RESTORAN NASI KANDAR SEBERANG
No. Resit: 88213
Tarikh: 03/03/2026
Nasi Campur                12.00
Teh Tarik                   3.00
JUMLAH KECIL               15.00
CUKAI PERKHIDMATAN 6%       0.90
JUMLAH                     15.90
TUNAI                      20.00
BAKI                        4.10
''';

    test('jumlah is the total and jumlah kecil is the subtotal', () {
      final read = parseReceiptText(text);
      expect(read.totalAmount, 15.90);
      expect(read.subtotal, 15.00);
      expect(read.taxAmount, 0.90);
    });

    test('tunai and baki are not mistaken for it', () {
      // BAKI is 4.10 and TUNAI is 20.00; picking either would be worse
      // than picking nothing.
      expect(parseReceiptText(text).totalAmount, 15.90);
    });

    test('a Malay month name is understood', () {
      const dated = 'Tarikh: 15 Mac 2026\nJUMLAH 20.00';
      expect(parseReceiptText(dated).documentDate, DateTime(2026, 3, 15));
    });
  });

  group('when the paper disagrees with itself', () {
    test('the printed figures are returned and the reader is told', () {
      const text = '''
KEDAI RUNCIT AMAN
SUBTOTAL   100.00
SST 8%       8.00
TOTAL      118.00
''';
      final read = parseReceiptText(text);
      // Not corrected to 108.00, and not corrected to a subtotal of
      // 110.00. A bookkeeper can reconcile a receipt that disagrees with
      // itself; they cannot reconcile one this code quietly fixed.
      expect(read.subtotal, 100.00);
      expect(read.taxAmount, 8.00);
      expect(read.totalAmount, 118.00);
      expect(read.note, contains('do not add up'));
    });

    test('nothing legible comes back as nothing, with a note', () {
      final read = parseReceiptText('~~~~\n....\n');
      expect(read.totalAmount, isNull);
      expect(read.supplierName, isNull);
      expect(read.note, contains('No total'));
    });
  });

  group('dates that could be read either way', () {
    test('an impossible month settles the order without guessing', () {
      // 25 cannot be a month, so this is 4 December however the printer
      // meant it.
      expect(parseReceiptText('Date: 12/25/2026\nTOTAL 10.00').documentDate,
          DateTime(2026, 12, 25));
    });

    test('an ambiguous one is read the Malaysian way', () {
      expect(parseReceiptText('Date: 06/07/2026\nTOTAL 10.00').documentDate,
          DateTime(2026, 7, 6));
    });

    test('an impossible date is refused rather than rolled over', () {
      // DateTime(2026, 2, 31) silently becomes 3 March. A date the
      // reader misread should come back absent, not wrong.
      expect(parseReceiptText('Date: 31/02/2026\nTOTAL 10.00').documentDate,
          isNull);
    });

    test('the date beside the word wins over one printed earlier', () {
      const text = 'Due 01/01/2027\nTarikh: 09/09/2026\nJUMLAH 10.00';
      expect(parseReceiptText(text).documentDate, DateTime(2026, 9, 9));
    });
  });

  group('figures split from their label', () {
    test('a total on the line below its label is still found', () {
      // Column layouts photograph badly and ML Kit returns the label and
      // the figure as separate lines often enough to matter.
      const text = 'KEDAI SERBANEKA\nTOTAL\n45.90\n';
      expect(parseReceiptText(text).totalAmount, 45.90);
    });

    test('but a label followed by another label takes nothing', () {
      const text = 'KEDAI SERBANEKA\nTOTAL\nCASH\n50.00\n';
      expect(parseReceiptText(text).totalAmount, isNull);
    });
  });

  // The three parsers the hand-assignment screen uses. They exist so
  // that a field somebody assigns by hand means the same thing as one
  // the reader found on its own — a second opinion about what
  // `07/04/2026` says is how a receipt lands in the wrong month — and
  // none of them was called by a test.
  group('a date off one line', () {
    test('is read day first, because this is Malaysia', () {
      // 7 April, not 4 July. On a ledger with period control, the
      // difference is a posting in the wrong month that foots perfectly.
      expect(parseReceiptDate('07/04/2026'), DateTime(2026, 4, 7));
      expect(parseReceiptDate('07-04-2026'), DateTime(2026, 4, 7));
    });

    test('and the unambiguous spellings agree with it', () {
      expect(parseReceiptDate('2026-04-07'), DateTime(2026, 4, 7));
      expect(parseReceiptDate('7 Apr 2026'), DateTime(2026, 4, 7));
    });

    test('a day past the twelfth settles the question either way', () {
      // 31/12 and 13/01 can only be read one way round, so they pin the
      // order down independently of the rule above.
      expect(parseReceiptDate('31/12/2025'), DateTime(2025, 12, 31));
      expect(parseReceiptDate('13/01/2026'), DateTime(2026, 1, 13));
    });

    test('and a line with no date in it is not a date', () {
      expect(parseReceiptDate('no date here'), isNull);
      expect(parseReceiptDate(''), isNull);
    });

    test('it says the same thing the reader said', () {
      // The whole reason it is public. If these two ever disagree, a
      // receipt reads one way on the scan and another when somebody
      // corrects it.
      const receipt = 'KEDAI RUNCIT AMAN\nTarikh: 07/04/2026\nTOTAL 12.00';
      expect(parseReceiptText(receipt).documentDate,
          parseReceiptDate('07/04/2026'));
    });
  });

  group('a figure as printed or as typed', () {
    test('comes back whatever is around it', () {
      expect(parseAmountText('RM 1,234.56'), 1234.56);
      expect(parseAmountText('1234.56'), 1234.56);
      expect(parseAmountText('12'), 12);
    });

    test('a leading minus is kept', () {
      expect(parseAmountText('-5.00'), -5);
      expect(parseAmountText('RM-5.00'), -5);
    });

    test('and brackets come back positive, deliberately', () {
      // Recorded because it would be easy to read the stripping as a
      // bug. What this fills is a receipt's subtotal, tax and total, and
      // a retail receipt prints `TOTAL 12.00`; brackets on one are noise
      // around the figure or the reader mistaking a character. An
      // accounting statement, where brackets mean a credit, is not what
      // gets photographed.
      expect(parseAmountText('(12.00)'), 12);
    });

    test('a minus anywhere but the front is noise too', () {
      // There is no arithmetic in a printed figure.
      expect(parseAmountText('5-3'), 53);
    });

    test('and what is not a figure is nothing, never nought', () {
      // The distinction the empty box depends on: "not on the document"
      // is not "the document says zero".
      expect(parseAmountText(''), isNull);
      expect(parseAmountText('   '), isNull);
      expect(parseAmountText('abc'), isNull);
      expect(parseAmountText('.'), isNull);
      expect(parseAmountText('-'), isNull);
      expect(parseAmountText('1.2.3'), isNull);
    });
  });

  group('one printed line, split', () {
    test('the money at the end is the amount, and the rest is the words', () {
      final line = parseReceiptLine('Teh Tarik 3.50');
      expect(line.description, 'Teh Tarik');
      expect(line.amount, 3.50);
    });

    test('and where a line prices the unit as well, the last figure wins', () {
      // `2 x 5.00 10.00` — the ten is what the line cost. Taking the
      // first figure would book half of everything sold in twos.
      final line = parseReceiptLine('Nasi Lemak 2 x 5.00 10.00');
      expect(line.amount, 10.00);
      expect(line.description, 'Nasi Lemak 2 x 5.00');
    });

    test('a line with no money on it is still a description', () {
      final line = parseReceiptLine('Just a description');
      expect(line.description, 'Just a description');
      expect(line.amount, isNull);
    });

    test('and a line with nothing on it at all is nothing', () {
      // `scan_all_data` drops an assigned line only when both halves
      // are absent, so an empty description here would file a nameless
      // line against the document rather than refusing it.
      final line = parseReceiptLine('');
      expect(line.description, isNull);
      expect(line.amount, isNull);

      final spaces = parseReceiptLine('   ');
      expect(spaces.description, isNull);
      expect(spaces.amount, isNull);
    });

    test('and a bare figure is an amount with nothing said about it', () {
      // Not a description of "". `scan_all_data` drops a line only when
      // both halves are absent, so an empty string here would file a
      // nameless line rather than refusing it.
      final line = parseReceiptLine('12.00');
      expect(line.description, isNull);
      expect(line.amount, 12.00);
    });
  });

}
