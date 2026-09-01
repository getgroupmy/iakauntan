import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/data/models.dart';
import 'package:iakauntan/src/features/documents/invoice_pdf.dart';

/// The figures printed on an invoice add up to the total printed under
/// them.
///
/// That sounds like nothing to assert. It is the assertion that was
/// missing: `0410` added `service_charge_amount` to `sales_documents`,
/// taxed it, posted it to 4250 and put it in `total_amount`, and the
/// PDF's totals block was not told. A restaurant's tax invoice printed
///
///     Subtotal   100.00
///     Tax          8.80
///     Total      118.80
///
/// and nothing failed, because the tests on that PDF assert that it is a
/// PDF -- `%PDF-` at the front, `%%EOF` at the back, more than five
/// thousand bytes. All three still passed with ten ringgit missing off
/// the face of the document.
///
/// So this asserts the identity instead of the rows. A money column
/// added to the header and not to `invoiceTotalRows` fails the first
/// test below whether or not anybody thinks of this file, which is the
/// only property worth having here.
void main() {
  BusinessDocument doc({
    double subtotal = 0,
    double discount = 0,
    double shipping = 0,
    double serviceCharge = 0,
    double tax = 0,
    double rounding = 0,
    required double total,
  }) =>
      BusinessDocument(
        id: 'd',
        docType: 'invoice',
        docNo: 'INV-1',
        docDate: DateTime(2026, 1, 1),
        contactId: 'c',
        subtotal: subtotal,
        discountAmount: discount,
        shippingAmount: shipping,
        serviceChargeAmount: serviceCharge,
        taxAmount: tax,
        roundingAmount: rounding,
        totalAmount: total,
        balanceAmount: total,
        einvoiceStatus: 'not_applicable',
      );

  double footed(BusinessDocument d) =>
      invoiceTotalRows(d).fold<double>(0, (sum, r) => sum + r.amount);

  test('every figure on the bill at once, and it foots', () {
    // Deliberately all of them together rather than one shape per test.
    // A column left out of the block is only visible when the document
    // that carries it is the one being printed, and the document a
    // Malaysian restaurant sends carries all of these.
    final d = doc(
      subtotal: 100.00,
      discount: 7.50,
      shipping: 5.00,
      serviceCharge: 10.00,
      tax: 8.60,
      rounding: 0.02,
      total: 116.12,
    );
    expect(footed(d), closeTo(d.totalAmount, 0.005));
  });

  test('the restaurant bill that was wrong', () {
    // The worked example from `supabase/tests/pos_service_charge.sql`:
    // a hundred ringgit of food, ten per cent for the table, and eight
    // per cent service tax on the hundred and ten. Before the service
    // charge row existed this footed to 108.80 against a total of
    // 118.80.
    final d = doc(
      subtotal: 100.00,
      serviceCharge: 10.00,
      tax: 8.80,
      total: 118.80,
    );
    expect(footed(d), closeTo(118.80, 0.005));
    expect(
      invoiceTotalRows(d).map((r) => r.label),
      contains('Service charge'),
    );
  });

  test('and it is printed above the tax, because the tax is charged on it',
      () {
    final labels = invoiceTotalRows(doc(
      subtotal: 100.00,
      serviceCharge: 10.00,
      tax: 8.80,
      total: 118.80,
    )).map((r) => r.label).toList();
    // Both named first. `indexOf` answers -1 for a label that is not
    // there, and -1 is less than every index, so the ordering assertion
    // on its own passes when the row is missing entirely -- which is the
    // failure it is here to catch.
    expect(labels, containsAll(['Service charge', 'Tax']));
    expect(labels.indexOf('Service charge'), lessThan(labels.indexOf('Tax')));
  });

  test('a discount is shown as the negative it is', () {
    final rows = invoiceTotalRows(
        doc(subtotal: 100.00, discount: 10.00, total: 90.00));
    expect(rows.firstWhere((r) => r.label == 'Discount').amount, -10.00);
  });

  test('a plain bill lists nothing it does not have', () {
    // The zero rows are dropped, so this is also the assertion that the
    // dropping does not drop something that was not zero.
    final labels = invoiceTotalRows(doc(subtotal: 100.00, total: 100.00))
        .map((r) => r.label);
    expect(labels, ['Subtotal']);
  });

  test('an empty document still foots', () {
    expect(footed(doc(total: 0)), closeTo(0, 0.005));
  });

  test('a service charge with no tax on it foots too', () {
    // The stall in `pos_service_charge.sql`: it adds a charge and is not
    // registered for service tax, so there is nothing on top of it.
    expect(
      footed(doc(subtotal: 100.00, serviceCharge: 10.00, total: 110.00)),
      closeTo(110.00, 0.005),
    );
  });
}
