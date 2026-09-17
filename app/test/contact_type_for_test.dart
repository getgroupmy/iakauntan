import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/data/repository.dart';
import 'package:iakauntan/src/features/documents/doc_types.dart';

/// Who a document may be made out to.
///
/// A quotation is what you send somebody you have not sold to yet, so
/// the offer's picker includes prospects. An invoice records a sale,
/// so its picker does not: `transfer_document` (0478) lands the
/// accepted quotation on the company's customer record instead, and
/// refuses where there is none. These pin the app's half of that --
/// the filter each document asks for, and what the filter stands for
/// -- so widening the offer's filter to every document, or narrowing
/// it back to customers, fails here before it reaches a screen.
void main() {
  group('the picker each document asks for', () {
    test('an offer may be made to a prospect', () {
      expect(contactTypeFor('quotation'), 'customer_or_prospect');
      expect(contactTypeFor('proforma'), 'customer_or_prospect');
    });

    test('a sale may not', () {
      expect(contactTypeFor('sales_order'), 'customer');
      expect(contactTypeFor('delivery_order'), 'customer');
      expect(contactTypeFor('invoice'), 'customer');
      expect(contactTypeFor('credit_note'), 'customer');
    });

    test('and the buying side is untouched', () {
      expect(contactTypeFor('purchase_order'), 'supplier');
      expect(contactTypeFor('bill'), 'supplier');
    });
  });

  group('what a filter stands for', () {
    test('the offer picker is customers, both and prospects', () {
      expect(Repo.contactTypesFor('customer_or_prospect'), [
        'customer',
        'both',
        'prospect',
      ]);
    });

    test('customers and suppliers each take `both` with them', () {
      expect(Repo.contactTypesFor('customer'), ['customer', 'both']);
      expect(Repo.contactTypesFor('supplier'), ['supplier', 'both']);
    });

    test('a prospect listing is prospects only', () {
      expect(Repo.contactTypesFor('prospect'), ['prospect']);
    });

    test('all is no filter', () {
      expect(Repo.contactTypesFor('all'), isNull);
      expect(Repo.contactTypesFor(null), isNull);
    });
  });
}
