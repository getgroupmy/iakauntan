import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/features/documents/duplicate_bill.dart';

/// The bill that arrived twice. `0628`.
///
/// Paying a supplier's invoice twice is the most expensive routine
/// mistake in accounts payable, and this is the only thing in the
/// product that looks for it. What is asserted here is the WORDING,
/// which for a warning is the behaviour:
///
///   * **the two reasons are not equally good, and the screen must not
///     pretend they are.** A number match is near enough proof; an
///     amount-and-date match is a coincidence that happens. One
///     sentence covering both would have to be the weaker one, and a
///     warning that always hedges is a warning people learn to click
///     through — including on the day it was the strong kind.
///   * **the line has to be recognisable.** Somebody is holding a piece
///     of paper; the supplier's own number goes first, because that is
///     what is printed on it.
///   * **a draft is not a charge.** "You already have this" means
///     something different about a draft, a posted bill and one that
///     has already been paid.
void main() {
  DuplicateBill row({
    String reason = 'same number',
    String docNo = 'BILL-0042',
    String? supplierDocNo = 'INV-4471',
    String status = 'posted',
    double total = 1200,
    String date = '2026-05-01',
  }) => DuplicateBill.fromMap({
    'id': 'd1',
    'doc_no': docNo,
    'reason': reason,
    'total_amount': total,
    'currency': 'MYR',
    'status': status,
    'doc_date': date,
    'supplier_doc_no': supplierDocNo,
  });

  group('the two reasons are not the same warning', () {
    test('a number match is called what it is', () {
      final rows = [row()];
      expect(duplicatesAreStrong(rows), isTrue);
      expect(duplicateHeadline(rows), contains('invoice number'));
      expect(duplicateAdvice(rows), contains('paid twice'));
    });

    test('an amount-and-date match hedges, and says why', () {
      final rows = [row(reason: 'same amount on the same day')];
      expect(duplicatesAreStrong(rows), isFalse);
      expect(duplicateHeadline(rows), isNot(contains('invoice number')));
      // The sentence that keeps this from being ignored: it admits the
      // innocent explanation rather than crying wolf.
      expect(duplicateAdvice(rows), contains('two deliveries on one day'));
    });

    test('one strong match among weak ones makes the whole thing strong', () {
      final rows = [
        row(reason: 'same amount on the same day'),
        row(reason: 'same number'),
      ];
      expect(duplicatesAreStrong(rows), isTrue);
      expect(duplicateHeadline(rows), contains('more than once'));
    });

    test('nothing found says nothing', () {
      expect(duplicateHeadline(const []), '');
    });
  });

  group('the line somebody recognises the document from', () {
    test('the supplier’s own number comes first', () {
      final line = duplicateLine(row());
      expect(line, startsWith('No. INV-4471'));
      expect(line, contains('BILL-0042'));
      expect(line, contains('1,200.00'));
    });

    test('and is left out where the paper carried none', () {
      final line = duplicateLine(row(supplierDocNo: null));
      expect(line, isNot(contains('No.')));
      expect(line, startsWith('BILL-0042'));
    });

    test('a draft is not a charge, and the line says so', () {
      expect(duplicateLine(row(status: 'draft')), endsWith('still a draft'));
      expect(
        duplicateLine(row(status: 'completed')),
        endsWith('already paid'),
      );
      expect(duplicateLine(row(status: 'partial')), endsWith('part paid'));
      // A posted bill is the ordinary case and needs no qualifier.
      expect(duplicateLine(row(status: 'posted')), isNot(contains('—')));
    });
  });
}
