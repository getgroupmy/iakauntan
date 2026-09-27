import 'package:flutter_test/flutter_test.dart';
import 'package:iakauntan/src/features/property/statutory_charge_payment.dart';

Map<String, dynamic> charge({
  Object? bill,
  Object? paid,
  String? reference,
  Object? amount = 500,
  String? billNo,
}) => <String, dynamic>{
      'bill_document_id': bill,
      'paid_on': paid,
      'reference': reference,
      'amount': amount,
      'bill_no': billNo,
    };

void main() {
  group('which of the three a charge is in', () {
    test('nothing behind it and nothing paid is owed', () {
      expect(settlementOf(charge()), ChargeSettlement.unpaid);
      expect(describeSettlement(charge()), 'Owed');
    });

    test('a bill is the record even before the date catches up', () {
      final c = charge(bill: 'b1', billNo: 'BILL-9');
      expect(settlementOf(c), ChargeSettlement.bill);
      expect(describeSettlement(c), 'On bill BILL-9');
    });

    test('and says so once the bill is settled', () {
      final c = charge(bill: 'b1', paid: '2026-03-01', billNo: 'BILL-9');
      expect(describeSettlement(c), 'Paid, on bill BILL-9');
    });

    test('a date with a receipt behind it is outside the books', () {
      final c = charge(paid: '2026-03-01', reference: 'DBKL 8821');
      expect(settlementOf(c), ChargeSettlement.outsideTheBooks);
      expect(describeSettlement(c), 'Paid outside the books — DBKL 8821');
    });
  });

  group('the paid date, and what has to be behind it', () {
    test('no date, nothing to answer for', () {
      expect(
        paidDateBlockedBecause(
          hasBill: false, paidOn: null, reference: null),
        isNull,
      );
    });

    test('a date on its own is the thing being stopped', () {
      expect(
        paidDateBlockedBecause(
          hasBill: false, paidOn: DateTime(2026, 3, 1), reference: '  '),
        contains('receipt number'),
      );
    });

    test('a receipt makes it honest', () {
      expect(
        paidDateBlockedBecause(
          hasBill: false,
          paidOn: DateTime(2026, 3, 1),
          reference: 'Counter 12'),
        isNull,
      );
    });

    test('a billed charge is not asked, because the bill decides', () {
      expect(
        paidDateBlockedBecause(
          hasBill: true, paidOn: DateTime(2026, 3, 1), reference: null),
        isNull,
      );
    });
  });

  group('whether it can be billed', () {
    test('an unpaid charge with an amount can', () {
      expect(canBill(charge()), isTrue);
    });

    test('one already billed cannot, and says which bill', () {
      final c = charge(bill: 'b1', billNo: 'BILL-9');
      expect(canBill(c), isFalse);
      expect(whyNotBillable(c), 'Already on bill BILL-9.');
    });

    test('one already marked paid cannot, so there are not two records', () {
      final c = charge(paid: '2026-03-01', reference: 'r');
      expect(canBill(c), isFalse);
      expect(whyNotBillable(c), contains('one record of the payment'));
    });

    test('a nil charge cannot, because a bill is for something', () {
      final c = charge(amount: 0);
      expect(canBill(c), isFalse);
      expect(whyNotBillable(c), contains('nil'));
    });

    test('an amount that arrived as a string is still an amount', () {
      expect(canBill(charge(amount: '1250.00')), isTrue);
      expect(canBill(charge(amount: '0')), isFalse);
    });
  });

  group('the bill number, in either shape the row arrives in', () {
    // Every fixture above hands over the FLAT `bill_no`, which is
    // `site_screen`'s reshaping. The database does not send that
    // shape: `propertyStatutoryCharges` selects the number as an
    // embedded `purchase_documents(doc_no)`. Nothing here had ever
    // asked in that shape, and the sheet's "Bill it" tooltip — which
    // passes the row exactly as it came back — therefore dropped the
    // number and said only "Already on a bill."

    test('flat, as the site screen reshapes it', () {
      expect(billNoOf(charge(bill: 'b1', billNo: 'BILL-9')), 'BILL-9');
    });

    test('embedded, as the database sends it', () {
      final c = charge(bill: 'b1')
        ..['purchase_documents'] = {'doc_no': 'BILL-9'};
      expect(billNoOf(c), 'BILL-9');
      expect(describeSettlement(c), 'On bill BILL-9');
      expect(whyNotBillable(c), 'Already on bill BILL-9.');
    });

    test('and neither is still an answer, not a crash', () {
      final c = charge(bill: 'b1');
      expect(billNoOf(c), isNull);
      expect(describeSettlement(c), 'On a bill');
      expect(whyNotBillable(c), 'Already on a bill.');
    });
  });
}
