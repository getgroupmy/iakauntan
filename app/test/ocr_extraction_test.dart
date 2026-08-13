import 'package:flutter_test/flutter_test.dart';
import 'package:iakauntan/src/data/ocr_repository.dart';

/// What comes back from a reader is JSON somebody else's model produced,
/// and the fields it leaves out are as meaningful as the ones it fills.
/// These assert the two things the forms downstream depend on: that a
/// missing figure stays missing rather than becoming a zero, and that
/// the amount put in an expense's Amount box is the net rather than the
/// tax-inclusive total.
void main() {
  group('OcrExtraction', () {
    test('an absent figure is null, not zero', () {
      final read = OcrExtraction.fromJson({
        'supplier_name': 'Tenaga Nasional Berhad',
        'supplier_tax_id': null,
        'document_no': 'TNB-4471',
        'document_date': '2026-06-30',
        'currency': 'myr',
        'subtotal': null,
        'tax_amount': null,
        'total_amount': 214.35,
        'lines': [],
        'note': null,
      });

      // A receipt with no tax printed on it has no tax, and zero would
      // read as "printed as zero", which is a different document.
      expect(read.taxAmount, isNull);
      expect(read.subtotal, isNull);
      expect(read.totalAmount, 214.35);
      expect(read.supplierTaxId, isNull);
      expect(read.currency, 'MYR');
      expect(read.documentDate, DateTime(2026, 6, 30));
    });

    test('the amount to key is the net where the document separates it',
        () {
      final separated = OcrExtraction.fromJson({
        'subtotal': 100.00,
        'tax_amount': 8.00,
        'total_amount': 108.00,
        'lines': [],
      });
      // The form adds the tax back on from the tax code, so handing it
      // the gross would charge the tax twice.
      expect(separated.netAmount, 100.00);

      final oneFigure = OcrExtraction.fromJson({
        'subtotal': null,
        'tax_amount': null,
        'total_amount': 45.90,
        'lines': [],
      });
      expect(oneFigure.netAmount, 45.90);
    });

    test('blank strings are absent rather than empty', () {
      final read = OcrExtraction.fromJson({
        'supplier_name': '   ',
        'document_no': '',
        'note': null,
        'lines': [],
      });
      expect(read.supplierName, isNull);
      expect(read.documentNo, isNull);
    });

    test('a date the reader could not resolve does not become today', () {
      final read = OcrExtraction.fromJson({
        'document_date': 'sometime in June',
        'lines': [],
      });
      expect(read.documentDate, isNull);
    });

    test('lines survive with their own missing figures', () {
      final read = OcrExtraction.fromJson({
        'lines': [
          {
            'description': 'Petrol 95',
            'quantity': 32.5,
            'unit_price': null,
            'amount': 85.40,
          },
        ],
      });
      expect(read.lines, hasLength(1));
      expect(read.lines.single.description, 'Petrol 95');
      expect(read.lines.single.unitPrice, isNull);
      expect(read.lines.single.amount, 85.40);
    });
  });

  group('OcrSettings', () {
    test('an organization with no row reads as off', () {
      // `ocr_status` always answers, even where no settings row exists,
      // so the shape below is what an untouched organization returns.
      final off = OcrSettings.fromJson({
        'enabled': false,
        'provider': 'claude',
        'key_source': 'platform',
        'has_own_key': false,
        'keys': <String, dynamic>{},
        'balance': 0,
        'price': 0.30,
      });
      expect(off.enabled, isFalse);
      // Nothing is owed while nothing is switched on, so this must not
      // read as "out of credit" and put a warning on the settings page.
      expect(off.outOfCredit, isFalse);
    });

    test('out of credit only when the platform key is the one in use', () {
      final platform = OcrSettings.fromJson({
        'enabled': true,
        'provider': 'claude',
        'key_source': 'platform',
        'has_own_key': false,
        'keys': <String, dynamic>{},
        'balance': 0.10,
        'price': 0.30,
      });
      expect(platform.outOfCredit, isTrue);
      expect(platform.scansLeft, 0);

      // Their own key spends their own money at the provider, so this
      // balance is irrelevant and must not stop them scanning.
      final own = OcrSettings.fromJson({
        'enabled': true,
        'provider': 'claude',
        'key_source': 'own',
        'has_own_key': true,
        'keys': {'claude': true},
        'balance': 0,
        'price': 0.30,
      });
      expect(own.outOfCredit, isFalse);
      expect(own.keys, {'claude'});
    });

    test('what is left is counted down, not rounded up', () {
      final ocr = OcrSettings.fromJson({
        'enabled': true,
        'provider': 'claude',
        'key_source': 'platform',
        'has_own_key': false,
        'keys': <String, dynamic>{},
        'balance': 10.00,
        'price': 0.30,
      });
      // 33.33 scans is 33 scans. Promising 34 and refusing the last one
      // is how a number on a screen becomes a support ticket.
      expect(ocr.scansLeft, 33);
      expect(ocr.outOfCredit, isFalse);
    });
  });
}
