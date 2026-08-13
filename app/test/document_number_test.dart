import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/features/shared/receipt_text.dart';

/// The document's own number.
///
/// It is what a bill is matched against when the supplier chases it, and
/// what stops the same invoice being entered twice. The old matcher
/// demanded a colon after the label, so `INVOICE NO 12345` — spaces and
/// nothing else, which is how a great many tills print it — came back
/// empty.
void main() {
  group('found beside its label', () {
    test('with a colon', () {
      expect(parseReceiptText('Teguh Hardware Sdn Bhd\nInvoice No: INV-2026-0042')
          .documentNo, 'INV-2026-0042');
    });

    test('with nothing but spaces', () {
      expect(parseReceiptText('DirectD Retail & Wholesale Sdn Bhd\n'
              'INVOICE NO 12345678')
          .documentNo, '12345678');
    });

    test('with a hash', () {
      expect(parseReceiptText('Kedai Runcit Aman\nReceipt #A00913')
          .documentNo, 'A00913');
    });

    test('with a full stop after the label', () {
      expect(parseReceiptText('Aman Enterprise\nBill No. B-77120')
          .documentNo, 'B-77120');
    });

    test('in Malay', () {
      expect(parseReceiptText('Kedai Runcit Aman\nNo. Resit : R0099123')
          .documentNo, 'R0099123');
    });
  });

  group('found under its label', () {
    test('a number printed on the next line', () {
      expect(parseReceiptText('''
Teguh Hardware Sdn Bhd
TAX INVOICE NO
TI-2026-000581
Date 14/08/2026
''').documentNo, 'TI-2026-000581');
    });

    test('but not a word from the next line', () {
      // The line under the label is the date's label, not a number.
      expect(parseReceiptText('''
Teguh Hardware Sdn Bhd
INVOICE NO
CASHIER
TOTAL 12.50
''').documentNo, isNull);
    });
  });

  group('what is not a document number', () {
    test('a date beside a reference label', () {
      expect(parseReceiptText('Kedai Runcit Aman\nRef: 14/08/2026\nTOTAL 12.50')
          .documentNo, isNull);
    });

    test('a figure of money beside a bill label', () {
      expect(parseReceiptText('Syarikat Air\nBill Amount 128.40\nTOTAL 128.40')
          .documentNo, isNull);
    });

    test('a receipt that prints no number at all', () {
      expect(parseReceiptText('KEDAI RUNCIT AMAN\nROTI 2.50\nTOTAL 2.50')
          .documentNo, isNull);
    });
  });

  test('a strong label wins over a card slip reference printed above it', () {
    // The approval code comes off the terminal and is nothing to do with
    // the bill; it is also printed first, so a single pass taking the
    // first match would take the wrong one.
    final read = parseReceiptText('''
Teguh Hardware Sdn Bhd
REF NO 004521998877
INVOICE NO TI-2026-000581
TOTAL 334.89
''');
    expect(read.documentNo, 'TI-2026-000581');
  });

  test('a weak label is still better than nothing', () {
    expect(parseReceiptText('''
Kedai Runcit Aman
Order ID 8891-22
TOTAL 12.50
''').documentNo, '8891-22');
  });

  test('the number does not become a printed line', () {
    // The document number sits above the items on most invoices, and a
    // line matcher working on "text then a figure" would otherwise take
    // it as a charge.
    final read = parseReceiptText('''
Teguh Hardware Sdn Bhd
Invoice No INV-2026-0042
Paku 2 inci 12.00
TOTAL 12.00
''');
    expect(read.documentNo, 'INV-2026-0042');
    expect(read.lines.map((l) => l.description), ['Paku 2 inci']);
  });
}
