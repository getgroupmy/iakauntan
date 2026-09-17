import 'package:flutter_test/flutter_test.dart';
import 'package:iakauntan/src/features/contacts/scanned_address.dart';

/// A reader hands back an address as printed, newlines and all, and
/// refuses to split it — its own comment says why: a Malaysian address
/// runs to four lines in no fixed order and guessing which line is the
/// city puts wrong data in a field that looks authoritative.
///
/// The contact form has four boxes, so something has to be decided.
/// These are about deciding as little as possible.
void main() {
  group('splitScannedAddress', () {
    test('the first line is the first line, the rest is the second', () {
      final a = splitScannedAddress(
        'No. 12, Jalan Damai\nTaman Sri Muda\n40400 Shah Alam\nSelangor',
      );
      expect(a.line1, 'No. 12, Jalan Damai');
      expect(a.line2, 'Taman Sri Muda, 40400 Shah Alam, Selangor');
    });

    test('a postcode at the end is taken out', () {
      final a = splitScannedAddress(
        'No. 12, Jalan Damai\nTaman Sri Muda\n40400 Shah Alam\nSelangor',
      );
      expect(a.postcode, '40400');
    });

    test('and the city is never guessed', () {
      // Shah Alam is right there on the same line as the postcode and is
      // still not taken: the field that would look most authoritative is
      // the one that would be wrong most often.
      final a = splitScannedAddress('Jalan Damai\n40400 Shah Alam, Selangor');
      expect(a.line1, 'Jalan Damai');
      expect(a.line2, '40400 Shah Alam, Selangor');
    });

    test('a building number at the top is not a postcode', () {
      final a = splitScannedAddress(
        'No. 12345, Jalan Perusahaan\nKawasan Perindustrian\nJohor',
      );
      expect(a.postcode, isNull);
    });

    test('nor a bare five-digit number near the top', () {
      // Not every stray five digits is introduced by "No." or "Lot" — a
      // building carries one, a plot carries one. What settles it is
      // *where* it is: a postcode is the end of a Malaysian address.
      final a = splitScannedAddress(
        'Wisma 12345\nJalan Damai\n40400 Shah Alam\nSelangor',
      );
      expect(a.postcode, '40400');
    });

    test('nor is a lot number', () {
      final a = splitScannedAddress('Lot 54321 Jalan Kilang\nJohor Bahru');
      expect(a.postcode, isNull);
    });

    test('a two-line address still finds its postcode', () {
      final a = splitScannedAddress('Jalan Besar\n81300 Skudai');
      expect(a.postcode, '81300');
      expect(a.line1, 'Jalan Besar');
      expect(a.line2, '81300 Skudai');
    });

    test('four digits are not a Malaysian postcode', () {
      final a = splitScannedAddress('Jalan Besar\n8130 Skudai');
      expect(a.postcode, isNull);
    });

    test('six digits are not one either', () {
      final a = splitScannedAddress('Jalan Besar\n813000 Somewhere');
      expect(a.postcode, isNull);
    });

    test('blank lines are dropped rather than kept as empty ones', () {
      final a = splitScannedAddress('Jalan Besar\n\n  \n81300 Skudai');
      expect(a.line2, '81300 Skudai');
    });

    test('nothing in, nothing out', () {
      final a = splitScannedAddress(null);
      expect(a.line1, '');
      expect(a.line2, '');
      expect(a.postcode, isNull);
    });

    test('one line is a first line and nothing else', () {
      final a = splitScannedAddress('Jalan Besar');
      expect(a.line1, 'Jalan Besar');
      expect(a.line2, '');
      expect(a.postcode, isNull);
    });
  });
}
