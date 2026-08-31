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
      for (final k in const [
        'quotation',
        'sales_order',
        'delivery_order',
        'purchase_request',
        'purchase_order',
        'goods_received',
      ]) {
        expect(metaFor(k).posts, isFalse, reason: k);
        expect(metaFor(k).settles, isFalse, reason: k);
        expect(metaFor(k).einvoice, isFalse, reason: k);
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
