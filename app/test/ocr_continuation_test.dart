import 'package:flutter_test/flutter_test.dart';
import 'package:iakauntan/src/data/ocr_repository.dart';

/// A charge on a supplier's bill often takes more than one printed line:
/// the item on the first, the detail on the second — a part number, a
/// period covered, a site address.
///
/// A reader asked for "one entry per printed line" hands that back as
/// two rows, the second carrying a description and no money. Left alone
/// it becomes a line on the bill at quantity one and price zero: a
/// phantom charge carrying the real charge's detail. Dropping it loses
/// what the company is being charged for.
///
/// The prompt now asks for the right shape. These are about what makes
/// the wrong shape harmless, because a reader swapped for another next
/// year does not get to reintroduce it.
void main() {
  group('foldOcrContinuations', () {
    test('a second printed line joins the item above it', () {
      final folded = foldOcrContinuations(const [
        OcrLine(
          description: 'Konsultansi sistem perakaunan',
          quantity: 1,
          unitPrice: 5000,
          amount: 5000,
        ),
        OcrLine(description: 'termasuk latihan 2 hari di premis'),
      ]);

      expect(folded, hasLength(1));
      expect(
        folded.single.description,
        'Konsultansi sistem perakaunan\ntermasuk latihan 2 hari di premis',
      );
      // And the money is the item's, untouched.
      expect(folded.single.amount, 5000);
      expect(folded.single.quantity, 1);
    });

    test('three printed lines are still one charge', () {
      final folded = foldOcrContinuations(const [
        OcrLine(
          description: 'Servis penyelenggaraan',
          quantity: 1,
          unitPrice: 1200,
          amount: 1200,
        ),
        OcrLine(description: 'No. siri: MX-4471-A'),
        OcrLine(description: 'Tempoh: Jan 2026 hingga Jun 2026'),
      ]);

      expect(folded, hasLength(1));
      expect(
        folded.single.description,
        'Servis penyelenggaraan\n'
        'No. siri: MX-4471-A\n'
        'Tempoh: Jan 2026 hingga Jun 2026',
      );
    });

    test('two real charges stay two', () {
      final folded = foldOcrContinuations(const [
        OcrLine(
          description: 'Kertas A4',
          quantity: 10,
          unitPrice: 12,
          amount: 120,
        ),
        OcrLine(
          description: 'Dakwat pencetak',
          quantity: 2,
          unitPrice: 85,
          amount: 170,
        ),
      ]);

      expect(folded, hasLength(2));
      expect(folded.first.description, 'Kertas A4');
      expect(folded.last.description, 'Dakwat pencetak');
    });

    test('a continuation only ever joins the charge above it', () {
      final folded = foldOcrContinuations(const [
        OcrLine(
          description: 'Kertas A4',
          quantity: 10,
          unitPrice: 12,
          amount: 120,
        ),
        OcrLine(description: '80gsm, putih'),
        OcrLine(
          description: 'Dakwat pencetak',
          quantity: 2,
          unitPrice: 85,
          amount: 170,
        ),
      ]);

      expect(folded, hasLength(2));
      expect(folded.first.description, 'Kertas A4\n80gsm, putih');
      expect(folded.first.amount, 120);
      expect(folded.last.description, 'Dakwat pencetak');
      expect(folded.last.amount, 170);
    });

    test('a first row with no price is kept, not swallowed', () {
      // It may be a genuine item whose price the reader could not make
      // out. A rule that swallows the first line of a document would be
      // worse than the problem it fixes, and there is nothing above it
      // to fold into anyway.
      final folded = foldOcrContinuations(const [
        OcrLine(description: 'Yuran perkhidmatan'),
        OcrLine(
          description: 'Kertas A4',
          quantity: 10,
          unitPrice: 12,
          amount: 120,
        ),
      ]);

      expect(folded, hasLength(2));
      expect(folded.first.description, 'Yuran perkhidmatan');
      expect(folded.first.amount, isNull);
    });

    test('a row with a quantity is a charge, however it was priced', () {
      // "2 × free replacement" is a line on the bill even at nothing,
      // and folding it into the item above would misdescribe both.
      final folded = foldOcrContinuations(const [
        OcrLine(
          description: 'Kertas A4',
          quantity: 10,
          unitPrice: 12,
          amount: 120,
        ),
        OcrLine(description: 'Gantian percuma', quantity: 2),
      ]);

      expect(folded, hasLength(2));
      expect(folded.last.description, 'Gantian percuma');
    });

    test('a row with neither words nor money is dropped', () {
      final folded = foldOcrContinuations(const [
        OcrLine(
          description: 'Kertas A4',
          quantity: 10,
          unitPrice: 12,
          amount: 120,
        ),
        OcrLine(description: '   '),
      ]);

      expect(folded, hasLength(1));
      expect(folded.single.description, 'Kertas A4');
    });

    test('nothing in, nothing out', () {
      expect(foldOcrContinuations(const []), isEmpty);
    });
  });
}
