import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:iakauntan/src/data/models.dart';
import 'package:iakauntan/src/features/documents/doc_types.dart';

/// The table one editor serves the whole document cycle from.
///
/// Three booleans on each row decide real things: `posts` writes a
/// journal entry, `einvoice` offers submission to LHDN, and `settles`
/// says the document carries a balance payments are applied against.
/// The table had no test at all, and every way of getting a flag wrong
/// is quiet — a quotation marked `posts` writes a journal for a quote,
/// and an invoice missing `einvoice` is left out of MyInvois with
/// nothing on the screen to say why.
///
/// Asserted as invariants rather than row by row, so a document type
/// added later is held to the same rules instead of arriving
/// unexamined.
void main() {
  group('every document type', () {
    test('is named in both numbers, and differently', () {
      for (final e in docTypes.entries) {
        expect(e.value.singular, isNotEmpty, reason: e.key);
        expect(e.value.plural, isNotEmpty, reason: e.key);
        expect(e.value.plural, isNot(e.value.singular), reason: e.key);
      }
    });

    test('belongs to exactly one cycle', () {
      final sales = docTypesFor(DocKind.sales).map((e) => e.key).toSet();
      final purchase = docTypesFor(DocKind.purchase).map((e) => e.key).toSet();

      expect(sales.intersection(purchase), isEmpty);
      // Nothing left over: a type in neither list is a type the switcher
      // cannot reach, which is how a document becomes unraisable.
      expect(sales.union(purchase), docTypes.keys.toSet());
    });
  });

  group('against the two enums the database keeps', () {
    /// The values of one `create type app.X as enum`, read out of the
    /// migration that declares it. Read rather than copied: a copied
    /// list is one that drifts, and the drift is what this group is
    /// for — three types were fully implemented in SQL and had no row
    /// in the table, so the app could neither raise them nor name them.
    Set<String> enumValues(String file, String type) {
      final sql = File('../supabase/migrations/$file').readAsStringSync();
      final block = RegExp(
        'create type app\\.$type as enum \\(([^)]*)\\)',
        dotAll: true,
      ).firstMatch(sql);
      expect(block, isNotNull, reason: '$type moved; this test is stale');
      return RegExp("'([a-z_]+)'")
          .allMatches(block!.group(1)!)
          .map((m) => m.group(1)!)
          .toSet();
    }

    /// `purchase_return`, and why it is named here rather than offered.
    ///
    /// It is the one value of the seven that no posting path accepts:
    /// `0013` and `0097` both list the purchase types they will post and
    /// it is not among them. The word appears in the migrations, but as
    /// a `stock_movement_type` — the goods going back — which is a
    /// different enum and a movement rather than a document.
    ///
    /// Giving it a row would put an entry in the menu that raises a
    /// document nothing can post: a draft that stays a draft, with the
    /// refusal arriving after the lines are typed. It stays out until
    /// something posts it, and this is where to delete it from.
    const notRaisable = {'purchase_return'};

    test('the sales table offers every type the database can post', () {
      final inSql = enumValues('0005_sales.sql', 'sales_doc_type');
      expect(inSql.length, greaterThan(6));

      final offered = docTypesFor(DocKind.sales).map((e) => e.key).toSet();
      expect(
        inSql.difference(offered).difference(notRaisable),
        isEmpty,
        reason: 'a sales document the database allows and nothing can raise',
      );
      // And the other way: a type no enum value matches is a 22P02 the
      // moment somebody presses Save.
      expect(offered.difference(inSql), isEmpty);
    });

    test('and the purchase table does too', () {
      final inSql = enumValues('0006_purchases_inventory.sql',
          'purchase_doc_type');
      expect(inSql.length, greaterThan(5));

      final offered = docTypesFor(DocKind.purchase).map((e) => e.key).toSet();
      expect(
        inSql.difference(offered).difference(notRaisable),
        isEmpty,
        reason: 'a purchase document the database allows and nothing can raise',
      );
      expect(offered.difference(inSql), isEmpty);
    });

    test('all four of LHDN\'s e-Invoice types can be raised', () {
      // 0015 maps exactly these to 01, 02, 03 and 04, and raises on
      // anything else. Named literally rather than derived from the same
      // map, because the claim is about MyInvois rather than about us:
      // a company that can issue an invoice, a credit note and a debit
      // note and not a refund note is short of a statutory document, and
      // deriving the list from `docTypes` would make that unsayable.
      final submittable = {
        for (final e in docTypes.entries)
          if (e.value.einvoice) e.key,
      };
      expect(submittable, {
        'invoice',
        'credit_note',
        'debit_note',
        'refund_note',
      });
    });
  });

  group('what a flag commits the editor to', () {
    test('nothing carries a balance unless it posts one', () {
      // A quotation with `settles` would put a quote on the aged
      // listing, against a control account it never debited.
      for (final e in docTypes.entries) {
        if (e.value.settles) {
          expect(e.value.posts, isTrue, reason: e.key);
        }
      }
    });

    test('and nothing reaches LHDN unless it posts either', () {
      // MyInvois is a statement about a supply that happened. A
      // quotation is an offer.
      for (final e in docTypes.entries) {
        if (e.value.einvoice) {
          expect(e.value.posts, isTrue, reason: e.key);
        }
      }
    });

    test('the two that settle are the two subsidiary ledgers', () {
      // Receivables and payables, and nothing else. A credit note is
      // applied through `payment_allocations` rather than carrying a
      // balance of its own, which is what 0269 and 0272 both depend on.
      final settling = {
        for (final e in docTypes.entries)
          if (e.value.settles) e.key,
      };
      expect(settling, {'invoice', 'bill'});
    });

    test('and only our own documents are ours to submit', () {
      // A purchase credit note is the supplier's document. Submitting
      // it would be filing somebody else's e-Invoice under our TIN.
      for (final e in docTypes.entries) {
        if (e.value.einvoice) {
          expect(e.value.kind, DocKind.sales, reason: e.key);
        }
      }
      expect(metaFor('purchase_credit_note').einvoice, isFalse);
    });

    test('the paperwork before the sale posts nothing', () {
      // Quotation, order, delivery order — and their purchase-side
      // counterparts. None of them is an accounting event.
      //
      // `goods_received` used to be on this list and is not: goods
      // arriving IS an accounting event, and treating it as paperwork
      // is what `0609` fixed. See the group below.
      for (final k in const [
        'quotation',
        'sales_order',
        'delivery_order',
        'purchase_request',
        'purchase_order',
      ]) {
        expect(metaFor(k).posts, isFalse, reason: k);
        expect(metaFor(k).settles, isFalse, reason: k);
        expect(metaFor(k).einvoice, isFalse, reason: k);
      }
    });
  });

  group('the goods arriving is an accounting event', () {
    // `0609`. A receiving note wrote nothing anywhere — no journal
    // and, despite what `post_purchase_document` assumed, no stock
    // movement either — so ten units bought through one reached the
    // shelf nowhere. Measured:
    //
    //   PO -> Bill          : 1 movement(s), 10.0000 received
    //   PO -> GRN -> Bill   : 0 movement(s), 0 received
    //
    // `goods_received.sql` asserts the arithmetic. These assert the
    // three flags on the row that let the editor offer it at all.
    test('so a receiving note posts', () {
      expect(metaFor('goods_received').posts, isTrue);
    });

    test('through a function of its own', () {
      // Not `post_purchase_document`, which refuses it by name: a
      // receiving note is not a bill. It accrues what will be owed
      // rather than recording it as payable.
      expect(metaFor('goods_received').postRpc, 'post_goods_received');
    });

    test('and it is the only type that needs one', () {
      // Every other document goes through the function for its kind.
      // If a second one ever needs its own, somebody should have to
      // come here and say which and why.
      final overridden = {
        for (final e in docTypes.entries)
          if (e.value.postRpc != null) e.key,
      };
      expect(overridden, {'goods_received'});
    });

    test('but it carries no balance and reaches no registry', () {
      // The supplier is not in the payables ledger until the bill
      // arrives, and a receiving note is nobody's e-Invoice.
      expect(metaFor('goods_received').settles, isFalse);
      expect(metaFor('goods_received').einvoice, isFalse);
    });

    test('and an overridden posting function is only ever set on a type that posts', () {
      for (final e in docTypes.entries) {
        if (e.value.postRpc != null) {
          expect(e.value.posts, isTrue, reason: e.key);
        }
      }
    });
  });

  group('a type the table does not know', () {
    test('reads as an invoice rather than as nothing', () {
      // Recorded rather than endorsed. The fallback keeps the editor
      // usable for a document type added to the database and not here,
      // at the cost of claiming three capabilities that type may not
      // have. The alternative — a neutral meta — silently stops a real
      // document posting, which is the worse of the two.
      expect(metaFor('something_new').singular, 'Invoice');
      expect(metaFor('').singular, 'Invoice');
    });

    test('and a known one reads as itself', () {
      expect(metaFor('bill').singular, 'Bill');
      expect(metaFor('credit_note').kind, DocKind.sales);
    });
  });
}
