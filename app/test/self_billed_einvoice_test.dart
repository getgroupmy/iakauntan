import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/data/models.dart';
import 'package:iakauntan/src/features/documents/doc_types.dart';

/// The e-Invoice a buyer owes LHDN for a supply the seller cannot file.
///
/// `self_billed_einvoice.sql` asserts the figures and, above all, which
/// company lands in which block. These assert the three flags on the
/// document-type table that decide whether the button appears at all,
/// and the one invariant that keeps them from contradicting each other.
///
/// The condition in the editor is two questions, not one: the TYPE has
/// to be capable of a self-billed e-Invoice, and the particular bill has
/// to owe one. A bill from a Malaysian supplier who files their own is
/// `selfBillable` and owes nothing, and a button offered there invites
/// somebody to file a second e-Invoice for a supply LHDN already has
/// one for.
void main() {
  group('which documents can carry a self-billed e-Invoice', () {
    test('the three purchase documents that post', () {
      // A purchase order is not one: nothing has been supplied yet. A
      // goods received note is not one either -- goods arriving is not
      // the supply being priced.
      final selfBillable = {
        for (final e in docTypes.entries)
          if (e.value.selfBillable) e.key,
      };
      expect(selfBillable, {
        'bill',
        'purchase_credit_note',
        'purchase_debit_note',
      });
    });

    test('and none of them is one we file as the seller', () {
      // The two are not alternatives for the same reason: an invoice is
      // a supply we MADE and a self-billed invoice is one we RECEIVED.
      // A document that claimed both would be filed twice, under two
      // type codes, for one transaction.
      for (final e in docTypes.entries) {
        if (e.value.selfBillable) {
          expect(e.value.einvoice, isFalse, reason: e.key);
        }
        if (e.value.einvoice) {
          expect(e.value.selfBillable, isFalse, reason: e.key);
        }
      }
    });

    test('nothing self-billable is on the sales side', () {
      for (final e in docTypes.entries) {
        if (e.value.selfBillable) {
          expect(e.value.kind, DocKind.purchase, reason: e.key);
        }
      }
    });

    test('and nothing carries one without posting', () {
      // LHDN is told about a supply that happened. A draft is not one.
      for (final e in docTypes.entries) {
        if (e.value.selfBillable) {
          expect(e.value.posts, isTrue, reason: e.key);
        }
      }
    });

    test('a purchase order and a receiving note carry none', () {
      // Named rather than left to the set assertion above, because
      // these are the two somebody would reach for: both are purchase
      // documents and neither is a priced supply.
      expect(metaFor('purchase_order').selfBillable, isFalse);
      expect(metaFor('goods_received').selfBillable, isFalse);
      expect(metaFor('purchase_request').selfBillable, isFalse);
    });
  });

  group('what the document says about itself', () {
    BusinessDocument doc({bool? requires}) => BusinessDocument.fromJson({
      'id': 'd',
      'doc_type': 'bill',
      'doc_no': 'BILL-1',
      'doc_date': '2026-01-15',
      'status': 'posted',
      if (requires != null) 'requires_self_billed': requires,
    });

    test('a bill nobody marked owes nothing', () {
      expect(doc().requiresSelfBilled, isFalse);
    });

    test('and a bill the database marked does', () {
      expect(doc(requires: true).requiresSelfBilled, isTrue);
    });

    test('an absent column is no, not yes', () {
      // The column has been `not null default false` since 0006, so an
      // absent key means a server that predates 0611 sending the row
      // through some narrower select. Defaulting it to true there would
      // offer to file an e-Invoice for every bill in the ledger.
      final d = BusinessDocument.fromJson({
        'id': 'd',
        'doc_type': 'bill',
        'doc_no': 'BILL-2',
        'doc_date': '2026-01-15',
      });
      expect(d.requiresSelfBilled, isFalse);
    });

    test('and a string is not a yes either', () {
      // PostgREST sends booleans as booleans, but a row that came
      // through a jsonb payload can carry "true" as text. `== true` is
      // the strict read, deliberately.
      final d = BusinessDocument.fromJson({
        'id': 'd',
        'doc_type': 'bill',
        'doc_no': 'BILL-3',
        'doc_date': '2026-01-15',
        'requires_self_billed': 'true',
      });
      expect(d.requiresSelfBilled, isFalse);
    });
  });
}
