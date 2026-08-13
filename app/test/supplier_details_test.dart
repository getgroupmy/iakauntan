import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/features/shared/receipt_text.dart';

/// The supplier's own particulars, off the letterhead.
///
/// These end up on a contact record rather than on one document, so a
/// wrong one is not a wrong bill — it is a wrong address on every
/// remittance after it, and an e-Invoice rejected for a registration
/// number that belongs to nobody. Hence the bias throughout: null unless
/// the document plainly says.
void main() {
  group('SSM registration number', () {
    test('the twelve-digit number is preferred where both are printed', () {
      final read = parseReceiptText('''
TM Technology Services Sdn Bhd
200201003726 (571389-H)
Jalan Pantai Baharu
50672 Kuala Lumpur
''');
      expect(read.supplierRegistrationNo, '200201003726');
    });

    test('the old form is kept where it is the only one', () {
      final read = parseReceiptText('''
Teguh Hardware Sdn Bhd
Co. Reg: 571389-H
No 12 Jalan Sultan
41000 Klang
''');
      expect(read.supplierRegistrationNo, '571389-H');
    });

    test('a labelled old number still loses to a printed new one', () {
      final read = parseReceiptText('''
Sinar Teknologi Sdn Bhd
Co. Reg: 571389-H
SSM: 201901030189
''');
      expect(read.supplierRegistrationNo, '201901030189');
    });

    test('a twelve-digit account number is not a registration', () {
      final read = parseReceiptText('''
Kedai Runcit Aman
Account 8899001122334455
Jumlah 12.50
''');
      expect(read.supplierRegistrationNo, isNull);
    });

    test('spaces around the old form are closed up', () {
      final read = parseReceiptText('''
Aman Enterprise
Reg No : 123456 - K
''');
      expect(read.supplierRegistrationNo, '123456-K');
    });
  });

  group('email', () {
    test('an address on the letterhead is kept', () {
      final read = parseReceiptText('''
Teguh Hardware Sdn Bhd
billing@teguh.com.my
''');
      expect(read.supplierEmail, 'billing@teguh.com.my');
    });

    test('a receipt with no address gets none', () {
      final read = parseReceiptText('Kedai Runcit Aman\nTOTAL 12.50');
      expect(read.supplierEmail, isNull);
    });
  });

  group('telephone', () {
    test('a labelled number wins over anything else on the page', () {
      final read = parseReceiptText('''
Teguh Hardware Sdn Bhd
Approval Code 004521998877
Tel: 03-5566 7788
''');
      expect(read.supplierPhone, '03-5566 7788');
    });

    test('a mobile on the letterhead is found unlabelled', () {
      final read = parseReceiptText('''
Kedai Runcit Aman
012-345 6789
Jalan Besar
''');
      expect(read.supplierPhone, '012-345 6789');
    });

    test('a 1-300 line is recognised', () {
      final read = parseReceiptText('''
TM Technology Services Sdn Bhd
Careline 1-300-88-9515
''');
      expect(read.supplierPhone, '1-300-88-9515');
    });

    test('a till roll with no telephone gets none', () {
      final read = parseReceiptText('Kedai Runcit Aman\nTOTAL 12.50');
      expect(read.supplierPhone, isNull);
    });
  });

  group('address', () {
    test('the block around the postcode is taken whole', () {
      final read = parseReceiptText('''
Teguh Hardware Sdn Bhd
No 12, Jalan Sultan Ismail
Taman Perindustrian
41000 Klang, Selangor
Tel: 03-5566 7788
''');
      expect(read.supplierAddress, contains('Jalan Sultan Ismail'));
      expect(read.supplierAddress, contains('41000 Klang'));
      // The company name heads the letterhead; it is not the address.
      expect(read.supplierAddress, isNot(contains('Teguh Hardware')));
      // Nor is the telephone line below it.
      expect(read.supplierAddress, isNot(contains('5566')));
    });

    test('no postcode, no guess', () {
      final read = parseReceiptText('''
Kedai Runcit Aman
Jalan Besar
TOTAL 12.50
''');
      expect(read.supplierAddress, isNull);
    });
  });

  test('a receipt carrying none of it says so rather than inventing it', () {
    final read = parseReceiptText('''
KEDAI RUNCIT AMAN
ROTI 2.50
TOTAL 2.50
''');
    expect(read.supplierRegistrationNo, isNull);
    expect(read.supplierEmail, isNull);
    expect(read.supplierAddress, isNull);
    expect(read.supplierTaxId, isNull);
  });

  test('the figures are unaffected by all of this', () {
    final read = parseReceiptText('''
Teguh Hardware Sdn Bhd
200201003726 (571389-H)
No 12, Jalan Sultan Ismail
41000 Klang
Tel: 03-5566 7788
SUBTOTAL 316.95
SST 8% 17.94
TOTAL 334.89
''');
    expect(read.subtotal, 316.95);
    expect(read.taxAmount, 17.94);
    expect(read.totalAmount, 334.89);
    expect(read.note, isNull);
  });
}
