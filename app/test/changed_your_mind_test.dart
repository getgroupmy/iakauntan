import 'package:flutter_test/flutter_test.dart';
import 'package:iakauntan/src/data/models.dart';
import 'package:iakauntan/src/features/documents/recurring_template_dialog.dart';
import 'package:iakauntan/src/features/stock/transfers_screen.dart';

BusinessDocument doc({
  required String no,
  String status = 'posted',
  String? contact = 'Sinar Teknologi',
  double total = 1200,
  String currency = 'MYR',
}) => BusinessDocument(
  id: 'id-$no',
  docType: 'invoice',
  docNo: no,
  docDate: DateTime(2026, 4, 1),
  contactId: 'c1',
  contactName: contact,
  currency: currency,
  exchangeRate: 1,
  subtotal: total,
  discountAmount: 0,
  taxAmount: 0,
  shippingAmount: 0,
  roundingAmount: 0,
  totalAmount: total,
  paidAmount: 0,
  balanceAmount: total,
  status: status,
  fulfilmentStatus: 'pending',
  einvoiceStatus: 'none',
);

void main() {
  group('calling off a transfer', () {
    test('only while it is still a draft', () {
      // "That transfer is % — the stock has already moved. Send it back
      // the other way rather than pretending it did not."
      expect(transferIsCancellable('draft'), isTrue);
      expect(transferIsCancellable('sent'), isFalse);
      expect(transferIsCancellable('received'), isFalse);
      expect(transferIsCancellable('cancelled'), isFalse);
      expect(transferIsCancellable(null), isFalse);
    });
  });

  group('which document a schedule can bill from', () {
    test('an invoice for a sales schedule, a bill for a purchase one', () {
      // update_recurring_template looks for one or the other by kind
      // and raises if it does not find it.
      expect(templateKindOf('sales'), DocKind.sales);
      expect(templateKindOf('purchase'), DocKind.purchase);
    });

    test('anything else is treated as sales, as the function does', () {
      expect(templateKindOf(null), DocKind.sales);
    });

    test('not a draft, which is something somebody is still typing', () {
      final list = templateCandidates([
        doc(no: 'INV-1', status: 'draft'),
        doc(no: 'INV-2'),
      ]);
      expect(list.map((d) => d.docNo), ['INV-2']);
    });

    test('not a voided one either', () {
      final list = templateCandidates([
        doc(no: 'INV-1', status: 'void'),
        doc(no: 'INV-2', status: 'paid'),
      ]);
      expect(list.map((d) => d.docNo), ['INV-2']);
    });

    test('a paid or part-paid invoice is a perfectly good template', () {
      // What is being copied is the lines and the prices, not the
      // balance.
      final list = templateCandidates([
        doc(no: 'INV-1', status: 'paid'),
        doc(no: 'INV-2', status: 'partial'),
      ]);
      expect(list, hasLength(2));
    });
  });

  group('what a candidate reads as', () {
    test('names the document, the party, the date and the money', () {
      final s = templateLabel(doc(no: 'INV-2026-0009', total: 1250.5));
      expect(s, contains('INV-2026-0009'));
      expect(s, contains('Sinar Teknologi'));
      expect(s, contains('1,250.50'));
    });

    test('a document with no party named still reads', () {
      final s = templateLabel(doc(no: 'INV-1', contact: null));
      expect(s, contains('INV-1'));
      expect(s, isNot(contains('null')));
    });

    test('a foreign invoice shows its own currency', () {
      final s = templateLabel(doc(no: 'INV-1', total: 900, currency: 'SGD'));
      expect(s, contains('SGD 900.00'));
    });
  });
}
