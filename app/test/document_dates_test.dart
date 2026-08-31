import 'package:flutter_test/flutter_test.dart';
import 'package:iakauntan/src/features/documents/document_dates.dart';
import 'package:iakauntan/src/features/documents/doc_types.dart';

/// Which document carries which date, and what the form says about it.
void main() {
  group('a validity belongs to an offer', () {
    test('a quotation and a proforma have one', () {
      expect(showsValidUntil('quotation'), isTrue);
      expect(showsValidUntil('proforma'), isTrue);
    });

    test('and nothing else does', () {
      // An invoice has a due date, which is a different fact: the day it
      // must be paid rather than the day the price stops holding.
      for (final k in docTypes.keys) {
        if (k == 'quotation' || k == 'proforma') continue;
        expect(showsValidUntil(k), isFalse, reason: k);
      }
    });
  });

  group('a promised delivery belongs to the goods', () {
    test('the documents about things moving carry one', () {
      for (final k in const [
        'quotation',
        'sales_order',
        'delivery_order',
        'purchase_order',
        'goods_received',
      ]) {
        expect(showsDeliveryDate(k), isTrue, reason: k);
      }
    });

    test('and an invoice does not', () {
      // `0374` deliberately does not carry a promise into an invoice: an
      // invoice's delivery date would be a statement about a delivery
      // that already happened, and copying a promise restates history.
      expect(showsDeliveryDate('invoice'), isFalse);
      expect(showsDeliveryDate('credit_note'), isFalse);
      expect(showsDeliveryDate('bill'), isFalse);
    });
  });

  group('the default a new quotation arrives with', () {
    test('is thirty days out', () {
      expect(defaultValidUntil(DateTime(2026, 5, 1)), DateTime(2026, 5, 31));
    });

    test('and rolls over a month end', () {
      expect(defaultValidUntil(DateTime(2026, 12, 20)), DateTime(2027, 1, 19));
    });
  });

  group('whether it has run out', () {
    final today = DateTime(2026, 5, 20);

    test('yesterday has', () {
      expect(quoteExpired(DateTime(2026, 5, 19), today: today), isTrue);
    });

    test('today has not — the last day is a day', () {
      expect(quoteExpired(DateTime(2026, 5, 20), today: today), isFalse);
    });

    test('and no date is not expired', () {
      // Every quotation raised before 0374 has none, and treating those
      // as expired would break every open quote in every company on the
      // day it applied.
      expect(quoteExpired(null, today: today), isFalse);
    });

    test('measured by the day, not the hour', () {
      expect(
        quoteExpired(DateTime(2026, 5, 20),
            today: DateTime(2026, 5, 20, 23, 59)),
        isFalse,
      );
    });
  });

  group('what the form says under the date', () {
    final today = DateTime(2026, 5, 20);

    test('nothing at all on a document without a validity', () {
      expect(validityNote('invoice', DateTime(2026, 6, 1), today: today),
          isNull);
    });

    test('nor on a quotation with a healthy date', () {
      expect(validityNote('quotation', DateTime(2026, 8, 1), today: today),
          isNull,
          reason: 'a form with nothing to say should say nothing');
    });

    test('that a missing date holds the price open indefinitely', () {
      expect(
        validityNote('quotation', null, today: today),
        contains('indefinitely'),
      );
    });

    test('that an expired one cannot be transferred', () {
      expect(
        validityNote('quotation', DateTime(2026, 5, 1), today: today),
        contains('cannot be turned into an order'),
      );
    });

    test('and counts the last week down', () {
      expect(
        validityNote('quotation', DateTime(2026, 5, 23), today: today),
        'Good for 3 more days.',
      );
      expect(
        validityNote('quotation', DateTime(2026, 5, 21), today: today),
        'Good for 1 more day.',
        reason: 'one day is a day, not 1 days',
      );
    });
  });
}
