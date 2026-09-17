import 'package:flutter_test/flutter_test.dart';
import 'package:iakauntan/src/data/models.dart';
import 'package:iakauntan/src/features/documents/deposit_apply_sheet.dart';

BusinessDocument doc({
  required String no,
  required String status,
  required double balance,
  String currency = 'MYR',
}) => BusinessDocument(
  id: 'id-$no',
  docType: 'invoice',
  docNo: no,
  docDate: DateTime(2026, 3, 1),
  contactId: 'c1',
  currency: currency,
  exchangeRate: 1,
  subtotal: balance,
  discountAmount: 0,
  taxAmount: 0,
  shippingAmount: 0,
  roundingAmount: 0,
  totalAmount: balance,
  paidAmount: 0,
  balanceAmount: balance,
  status: status,
  fulfilmentStatus: 'pending',
  einvoiceStatus: 'none',
);

void main() {
  group('what a deposit can go against', () {
    test('a posted or part-paid document, and nothing else', () {
      final docs = [
        doc(no: 'INV-1', status: 'draft', balance: 100),
        doc(no: 'INV-2', status: 'posted', balance: 100),
        doc(no: 'INV-3', status: 'partial', balance: 40),
        doc(no: 'INV-4', status: 'void', balance: 100),
      ];
      // apply_deposit: "% is %, and a deposit settles an outstanding
      // document."
      expect(
        applicableDocuments(docs, 'MYR').map((d) => d.docNo),
        ['INV-2', 'INV-3'],
      );
    });

    test('not one written in another currency', () {
      final docs = [
        doc(no: 'INV-1', status: 'posted', balance: 100, currency: 'SGD'),
        doc(no: 'INV-2', status: 'posted', balance: 100),
      ];
      // The function sends this case to a receipt instead, so the
      // exchange difference is struck where the rest of them are.
      expect(
        applicableDocuments(docs, 'MYR').map((d) => d.docNo),
        ['INV-2'],
      );
    });

    test('a deposit in another currency finds its own documents', () {
      final docs = [
        doc(no: 'INV-1', status: 'posted', balance: 100, currency: 'SGD'),
        doc(no: 'INV-2', status: 'posted', balance: 100),
      ];
      expect(
        applicableDocuments(docs, 'SGD').map((d) => d.docNo),
        ['INV-1'],
      );
    });

    test('nothing outstanding is nothing to apply to', () {
      final docs = [doc(no: 'INV-1', status: 'posted', balance: 0)];
      expect(applicableDocuments(docs, 'MYR'), isEmpty);
    });
  });

  group('how much', () {
    test('is the smaller of what is held and what is owed', () {
      expect(applicableAmount(500, 1200), 500);
      expect(applicableAmount(1200, 500), 500);
    });

    test('is equal when the two are', () {
      expect(applicableAmount(300, 300), 300);
    });

    test('rounds to the sen', () {
      expect(applicableAmount(100.007, 999), 100.01);
      // Not 0.30000000000000004, which is what the sum is.
      expect(applicableAmount(0.1 + 0.2, 999), 0.30);
    });

    test('never proposes a negative', () {
      expect(applicableAmount(-5, 100), 0);
    });
  });

  group('what was typed', () {
    test('a plain amount inside both balances', () {
      expect(
        applyAmountOf('250', depositBalance: 500, documentBalance: 1200),
        250,
      );
    });

    test('commas the way people type money', () {
      expect(
        applyAmountOf('1,250.50',
            depositBalance: 5000, documentBalance: 5000),
        1250.50,
      );
    });

    test('nothing, or nonsense, is not an amount', () {
      expect(
        applyAmountOf('', depositBalance: 500, documentBalance: 500),
        isNull,
      );
      expect(
        applyAmountOf('lima ratus',
            depositBalance: 500, documentBalance: 500),
        isNull,
      );
    });

    test('zero and below are refused, as the function refuses them', () {
      // "An application has to be for something."
      expect(
        applyAmountOf('0', depositBalance: 500, documentBalance: 500),
        isNull,
      );
      expect(
        applyAmountOf('-10', depositBalance: 500, documentBalance: 500),
        isNull,
      );
    });

    test('more than is left of the deposit is refused', () {
      expect(
        applyAmountOf('500.01', depositBalance: 500, documentBalance: 1200),
        isNull,
      );
    });

    test('more than the document owes is refused', () {
      expect(
        applyAmountOf('700', depositBalance: 5000, documentBalance: 699.99),
        isNull,
      );
    });

    test('exactly either balance is allowed', () {
      expect(
        applyAmountOf('500', depositBalance: 500, documentBalance: 1200),
        500,
      );
      expect(
        applyAmountOf('300', depositBalance: 500, documentBalance: 300),
        300,
      );
    });

    test('what is sent is what was compared', () {
      // The rounded figure is the return value, so the amount that
      // reaches apply_deposit is the one already checked against both
      // balances. Rounding again at the server cannot move it past one.
      final v = applyAmountOf(
        '499.996',
        depositBalance: 500,
        documentBalance: 500,
      )!;
      expect(v, 500);
      expect(v <= 500, isTrue);
    });

    test('a third decimal is rounded before it is compared', () {
      // apply_deposit rounds to two places and then compares. A figure
      // that rounds up past the balance has to be refused here too, or
      // the refusal arrives from the server for a reason nobody can see
      // on the screen.
      expect(
        applyAmountOf('500.004', depositBalance: 500, documentBalance: 900),
        500,
      );
      expect(
        applyAmountOf('500.006', depositBalance: 500, documentBalance: 900),
        isNull,
      );
    });
  });

  test('a document reads as its number and what it still owes', () {
    final label = applicableLabel(
      doc(no: 'INV-2026-0007', status: 'posted', balance: 1250.5),
    );
    expect(label, contains('INV-2026-0007'));
    expect(label, contains('1,250.50'));
  });
}
