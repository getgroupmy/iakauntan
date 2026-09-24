import 'package:flutter_test/flutter_test.dart';
import 'package:iakauntan/src/data/ocr_repository.dart';

/// What one scanned line's quantity and unit price should be.
///
/// A reader is asked for three figures per line — `quantity`,
/// `unit_price` and `amount` — and the document editor used the first
/// two and IGNORED THE THIRD whenever a unit price came back:
///
///     unitPrice: l.unitPrice ?? (l.amount != null ? amount / qty : 0)
///
/// So the printed amount, which is the figure the supplier's own total
/// is built from, was consulted only when there was nothing else. A
/// misread price column, or an invoice with a discount column the
/// reader was never asked about, produced a bill whose lines quietly
/// did not equal the paper. `0705`'s banner then said the document did
/// not tie to what was read — true, and silent about which line.
///
/// Three things are asserted here and each one is a real invoice:
///
///   * THE AMOUNT WINS. `unit_price` is `numeric(18,4)`, so 10.00 over
///     three stores as 3.3333 and extends to 9.9999, which the
///     2-decimal line total rounds to the printed 10.00. The document
///     ties to the paper by construction rather than by luck.
///   * A ROUNDED PRICE IS NOT A DISAGREEMENT. A unit price is printed to
///     two places all over Malaysia and meant to four. Reporting that
///     would put a notice on nearly every invoice and teach people to
///     ignore all of them.
///   * QUANTITY ZERO IS A MISREADING. Taken at face value it makes the
///     unit price zero and the charge vanishes off the bill.
void main() {
  group('the printed amount decides the line', () {
    test('quantity times price that agrees is left exactly as printed', () {
      final l = lineFromScan(
        const OcrLine(description: 'Toner', quantity: 3, unitPrice: 85, amount: 255),
      );

      expect(l.quantity, 3);
      // 85, not 85.0000-something derived. A line reads back the way
      // the paper does when there is no reason for it not to.
      expect(l.unitPrice, 85);
      expect(l.corrected, isNull);
    });

    test('a misread price is overruled by the amount, and said so', () {
      // The page prints 3 x 85.00 = 255.00 and the reader read the
      // price as 8.50. Using it would post a bill of 25.50 against an
      // invoice of 255.00.
      final l = lineFromScan(
        const OcrLine(description: 'Toner', quantity: 3, unitPrice: 8.5, amount: 255),
      );

      expect(l.quantity, 3);
      expect(l.unitPrice, 85);
      expect(l.corrected, isNotNull);
      expect(l.corrected, contains('255.00'));
      expect(l.corrected, contains('25.50'));
    });

    test('a discount column reads exactly like a misreading, and the '
        'amount is right in both', () {
      // 10 x 12.00 is 120.00 gross, less 10%, printed as 108.00. The
      // reader is not asked about discounts and never sees one; taking
      // the amount gets the charge right anyway.
      final l = lineFromScan(
        const OcrLine(description: 'Paper', quantity: 10, unitPrice: 12, amount: 108),
      );

      expect(l.unitPrice, closeTo(10.8, 0.00001));
      expect(l.corrected, isNotNull);
    });

    test('a price rounded for display is not a disagreement', () {
      // 3 x 3.33 is 9.99 and the line is printed as 10.00. The price
      // was rounded to two places for the page and means 3.3333. One
      // sen over three units is not a misreading and a notice about it
      // would appear on half the invoices in Malaysia.
      final l = lineFromScan(
        const OcrLine(description: 'Cable', quantity: 3, unitPrice: 3.33, amount: 10),
      );

      expect(l.corrected, isNull);
      expect(l.unitPrice, 3.33);
    });

    test('and the slack scales, because the rounding does', () {
      // A hundred units at a price rounded to two places can be fifty
      // sen out legitimately. 100 x 3.33 is 333.00 against a printed
      // 333.33 -- 33 sen, which is the price meaning 3.3333.
      final fine = lineFromScan(
        const OcrLine(description: 'Bolts', quantity: 100, unitPrice: 3.33,
            amount: 333.33),
      );
      expect(fine.corrected, isNull);

      // But a flat tolerance wide enough for that would swallow this:
      // one unit, and the price and the amount differ by a sen. There
      // is nowhere for rounding to hide on a single unit, so it is a
      // misread digit.
      final caught = lineFromScan(
        const OcrLine(description: 'Filing fee', quantity: 1,
            unitPrice: 250.01, amount: 250.00),
      );
      expect(caught.corrected, isNotNull);
      expect(caught.unitPrice, 250.00);
    });

    test('but half a sen on a single unit is', () {
      // Quantity one leaves nowhere for rounding to hide: the price IS
      // the amount, so any gap between them is a misread digit.
      final l = lineFromScan(
        const OcrLine(description: 'Service', quantity: 1, unitPrice: 500, amount: 5000),
      );

      expect(l.unitPrice, 5000);
      expect(l.corrected, isNotNull);
    });
  });

  /// The review dialog shows ONE editable figure per line: the amount.
  /// Quantity and unit price are carried through untouched and never
  /// drawn — "a bill's quantity and unit price are rarely what needs
  /// correcting, and two more boxes per line would make the common case
  /// worse to serve the rare one".
  ///
  /// Which means the old rule made that box INERT. Somebody looking at
  /// a misread line, correcting 255.00 to 155.00 and pressing Apply got
  /// a line of 3 x 85.00 = 255.00, because `unitPrice ?? ...` never
  /// reached the amount they had just typed. The one correction the
  /// dialog offers on a line was the one thing it could not do.
  group('the amount somebody corrected in the review dialog', () {
    test('is what the line becomes', () {
      final l = lineFromScan(
        const OcrLine(description: 'Toner', quantity: 3, unitPrice: 85,
            amount: 155),
      );

      expect(l.quantity, 3);
      expect(l.unitPrice, closeTo(155 / 3, 0.00001));
      // 3 x 51.6667 is 155.0001, which a 2-decimal line total rounds
      // back to the 155.00 that was typed.
      expect((l.quantity * l.unitPrice), closeTo(155, 0.005));
      expect(l.corrected, isNotNull);
    });

    test('and removing a line is still how a deposit comes off', () {
      // Not this function's job -- the dialog drops the row -- but the
      // line that survives must not be re-derived from a stale amount.
      final l = lineFromScan(
        const OcrLine(description: 'Deposit', quantity: 1, unitPrice: 0,
            amount: 0),
      );
      expect(l.unitPrice, 0);
      expect(l.corrected, isNull);
    });
  });

  group('what the reader did not give', () {
    test('no amount column leaves the extension as read', () {
      final l = lineFromScan(
        const OcrLine(description: 'Rent', quantity: 2, unitPrice: 750),
      );

      expect(l.quantity, 2);
      expect(l.unitPrice, 750);
      expect(l.corrected, isNull);
    });

    test('no price column derives one, with nothing to disagree about', () {
      final l = lineFromScan(
        const OcrLine(description: 'Sundry', quantity: 4, amount: 100),
      );

      expect(l.unitPrice, 25);
      expect(l.corrected, isNull);
    });

    test('no quantity is one', () {
      final l = lineFromScan(
        const OcrLine(description: 'Deposit', amount: 1500),
      );

      expect(l.quantity, 1);
      expect(l.unitPrice, 1500);
    });

    test('neither figure is a line at nothing, not a crash', () {
      final l = lineFromScan(const OcrLine(description: 'Note'));

      expect(l.quantity, 1);
      expect(l.unitPrice, 0);
      expect(l.corrected, isNull);
    });
  });

  group('quantity zero', () {
    test('is a misreading, and the charge is kept', () {
      // A printed 0 beside a real amount. Taken literally the unit
      // price becomes zero -- the old expression guarded the division
      // and produced exactly that -- and RM 320 disappears off the
      // bill with nothing to say it did.
      final l = lineFromScan(
        const OcrLine(description: 'Repairs', quantity: 0, amount: 320),
      );

      expect(l.quantity, 1);
      expect(l.unitPrice, 320);
    });

    test('and with a price beside it the money still survives', () {
      final l = lineFromScan(
        const OcrLine(description: 'Repairs', quantity: 0, unitPrice: 320, amount: 320),
      );

      expect(l.quantity, 1);
      expect(l.unitPrice, 320);
      expect(l.corrected, isNull);
    });
  });

  /// The sentence is read by somebody deciding whether to believe it,
  /// so it has to carry all three figures: what was read, what that
  /// comes to, and what the page says instead.
  group('the sentence', () {
    test('names the extension, the printed amount, and what was taken', () {
      final l = lineFromScan(
        const OcrLine(description: 'Toner', quantity: 2, unitPrice: 10, amount: 25),
      );

      expect(l.corrected, contains('2 x 10.00'));
      expect(l.corrected, contains('20.00'));
      expect(l.corrected, contains('25.00'));
    });

    test('a whole quantity has no decimals on it', () {
      // "2.00 x 15.00" is not how anybody writes it.
      final l = lineFromScan(
        const OcrLine(description: 'X', quantity: 2, unitPrice: 15, amount: 40),
      );
      expect(l.corrected, contains('2 x 15.00'));
      expect(l.corrected, isNot(contains('2.00 x')));
    });

    test('and a fractional one keeps them', () {
      final l = lineFromScan(
        const OcrLine(description: 'Hours', quantity: 1.5, unitPrice: 100, amount: 200),
      );
      expect(l.corrected, contains('1.50 x'));
    });
  });
}
