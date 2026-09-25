// What a scan is filed as, when the reader did not say.
//
// `0614` put `document_kind` on the scan so that the question a
// bookkeeper asks three months later -- what did it think this was --
// has an answer. The answer comes off the READER, which is right
// wherever the reader is the only one that saw the paper.
//
// It is wrong on a screen that already knew. The bank statement
// importer narrows the reader to `accounting.bank_statement` before the
// file is uploaded, and a reader narrowed to one destination is never
// asked to choose a kind -- so it returns none, and the scan is filed
// under nothing. The single scan in the live database is exactly that:
// twenty rows read out of a statement, `document_kind` null.
//
// Two things are asserted here.
//
// WHICH KIND WINS. The reader's, wherever it gave one; the caller's
// certainty only where it did not.
//
// AND THAT MOST DESTINATIONS HAVE NO CERTAINTY TO OFFER. A destination
// is where a reading GOES and a kind is what the paper IS, and the two
// are not one to one. Guessing would put a wrong answer where there is
// currently an honest blank -- and a blank reads as "nobody recorded
// this" while a wrong kind reads as the truth.
import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/data/ocr_repository.dart';
import 'package:iakauntan/src/features/shared/scan_runner.dart';
import 'package:iakauntan/src/features/smartscan/scan_destination.dart';

void main() {
  group('which kind is recorded', () {
    test('the reader answered, so the reader wins', () {
      expect(
        kindToRemember(
            const OcrExtraction(documentKind: 'name_card'), 'bank_statement'),
        'name_card',
      );
    });

    test('the reader said nothing, so the caller who knew is used', () {
      expect(
        kindToRemember(const OcrExtraction(), 'bank_statement'),
        'bank_statement',
      );
    });

    test('there was no reading at all, and it is still a bank statement', () {
      // The case this exists for as much as any: a statement that could
      // not be read is still a statement, and "a bank statement that
      // failed" is a far more useful thing to find later than "a
      // document of no kind that failed".
      expect(kindToRemember(null, 'bank_statement'), 'bank_statement');
    });

    test('neither said anything, and nothing is written', () {
      expect(kindToRemember(const OcrExtraction(), null), isNull);
      expect(kindToRemember(null, null), isNull);
    });

    test('an empty answer is not an answer', () {
      // A reader returning '' would otherwise beat a caller that knew,
      // and file the scan under a kind that is not a kind.
      expect(
        kindToRemember(const OcrExtraction(documentKind: '  '), 'bank_statement'),
        'bank_statement',
      );
      expect(kindToRemember(const OcrExtraction(documentKind: ''), '  '), isNull);
    });
  });

  group('what a destination is certain of', () {
    test('a bank statement, which is the whole point of this', () {
      expect(ScanDestination.bankStatement.knownKind, 'bank_statement');
    });

    test('and the three others that map to exactly one paper', () {
      expect(ScanDestination.goodsReceived.knownKind, 'delivery_order');
      expect(ScanDestination.expense.knownKind, 'receipt');
      expect(ScanDestination.bill.knownKind, 'bill');
    });

    test('a purchase order could be a quotation, so nothing is claimed', () {
      expect(ScanDestination.purchaseOrder.knownKind, isNull);
    });

    test("a sales invoice is not 0614's `bill`, which is a supplier's", () {
      expect(ScanDestination.invoice.knownKind, isNull);
    });

    test('a contact comes off a name card or an SSM profile', () {
      expect(ScanDestination.contact.knownKind, isNull);
    });

    test('and "not sure yet" is certain of nothing by definition', () {
      expect(ScanDestination.unknown.knownKind, isNull);
    });

    test('every kind named here is one 0614 actually seeded', () {
      // A code that is not in `scan_document_kinds` is refused by the
      // database, and `rememberDocumentKind` swallows the refusal --
      // so a typo here would record nothing at all, silently, on every
      // scan from that screen.
      const seeded = {
        'bill', 'receipt', 'quotation', 'delivery_order', 'bank_statement',
        'name_card', 'ssm_document', 'statement_of_account', 'other',
      };
      for (final d in ScanDestination.values) {
        final k = d.knownKind;
        if (k != null) expect(seeded, contains(k), reason: '$d');
      }
    });
  });
}
