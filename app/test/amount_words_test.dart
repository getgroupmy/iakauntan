import 'package:flutter_test/flutter_test.dart';
import 'package:iakauntan/src/core/amount_words.dart';

/// The words on a receipt and on a payment voucher. Both documents are
/// handled by hand and signed by hand, and the words are what stops a
/// figure being amended with a pen — so they have to be right, and the
/// two documents have to agree.
///
/// This lived inside `receipt_pdf.dart` and was never asserted. Moving
/// it so a voucher could share it is the moment to fix that: two copies
/// of this would drift, and a receipt and a voucher for the same
/// payment disagreeing about how much it was is the one thing neither
/// document may do.
void main() {
  group('amountInWords', () {
    test('ringgit and sen', () {
      expect(
        amountInWords(1234.56, 'MYR'),
        'Ringgit Malaysia one thousand two hundred and thirty four '
        'and fifty six sen only',
      );
    });

    test('a round figure says only', () {
      expect(amountInWords(500, 'MYR'), 'Ringgit Malaysia five hundred only');
    });

    test('one sen is not dropped', () {
      // The rounding here is the part that goes wrong: 0.01 of a double
      // is not 0.01, and a voucher that loses a sen is a voucher that
      // does not agree with the ledger.
      expect(amountInWords(10.01, 'MYR'),
          'Ringgit Malaysia ten and one sen only');
    });

    test('ninety nine sen rounds to ninety nine, not to a ringgit', () {
      expect(amountInWords(3.99, 'MYR'),
          'Ringgit Malaysia three and ninety nine sen only');
    });

    test('zero is a number a voucher can carry', () {
      expect(amountInWords(0, 'MYR'), 'Ringgit Malaysia zero only');
    });

    test('a million reads as a million', () {
      expect(amountInWords(1000000, 'MYR'),
          'Ringgit Malaysia one million only');
    });

    test('the teens are not tens and ones', () {
      expect(amountInWords(17, 'MYR'), 'Ringgit Malaysia seventeen only');
      expect(amountInWords(113, 'MYR'),
          'Ringgit Malaysia one hundred and thirteen only');
    });

    test('dollars have cents', () {
      expect(amountInWords(20.5, 'USD'), 'US Dollars twenty and fifty cents only');
    });

    test('a currency with no name printed says nothing at all', () {
      // Rather than inventing English words for a minor unit and
      // printing "fifty yen cents" on a document somebody signs.
      expect(amountInWords(50, 'JPY'), '');
      expect(amountInWords(50, 'SGD'), '');
    });
  });
}
