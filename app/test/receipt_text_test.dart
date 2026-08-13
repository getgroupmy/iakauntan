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
}
