import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/data/attachments_repository.dart';
import 'package:iakauntan/src/features/banking/statement_import.dart';

/// The same file, twice.
///
/// Asked for as "when the bank statement or ai scan or any file is
/// uploaded it should keep a copy of the file in storage so it can be
/// used back as[well as] will prevent duplicate upload of same file".
///
/// The first half was already true — `attachments` has kept every
/// upload since `0010` and `0708` refuses to delete one once anything
/// is built from it. The second half was not, because nothing knew what
/// a file CONTAINED: the same statement uploaded twice became a second
/// row, a second object, and a second scan, which is a second charge to
/// whichever reader the organization pays for.
///
/// `file_name` cannot answer it — `stampedFileName` puts the moment of
/// upload into every name, so two uploads of one file never share one.
/// `file_size` on its own is a coincidence waiting to happen.
void main() {
  Uint8List bytes(String s) => Uint8List.fromList(utf8.encode(s));

  _duplicateSentence();

  group('the hash of a file', () {
    test('is the published SHA-256, not something of our own', () {
      // The empty string's digest is the most widely published test
      // vector there is. Asserting a known-outside value is what makes
      // this a check rather than a restatement of whatever the code
      // happens to do.
      expect(
        contentHash(Uint8List(0)),
        'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
      );
      expect(
        contentHash(bytes('abc')),
        'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
      );
    });

    test('is lowercase hex, because 0711 refuses anything else', () {
      // The check constraint is `^[0-9a-f]{64}$`. A digest that came
      // back uppercase would be rejected by the database on insert —
      // and worse, a column that accepted both spellings would be one
      // where two copies of one file did not match each other.
      final h = contentHash(bytes('a statement'));

      expect(h, matches(RegExp(r'^[0-9a-f]{64}$')));
      expect(h, h.toLowerCase());
    });

    test('is the same for the same bytes and different for any change', () {
      expect(contentHash(bytes('same')), contentHash(bytes('same')));
      expect(contentHash(bytes('same')), isNot(contentHash(bytes('Same'))));
      // One byte longer. A length check would call these identical.
      expect(contentHash(bytes('same')), isNot(contentHash(bytes('same '))));
    });

    test('and two different files of the same length differ', () {
      // Which is the whole reason this is not `file_size`. Two bank
      // statements from the same bank in consecutive months are very
      // often byte-for-byte the same length.
      final a = bytes('01/08/2026 TRANSFER 1000.00');
      final b = bytes('01/09/2026 TRANSFER 1000.00');

      expect(a.length, b.length);
      expect(contentHash(a), isNot(contentHash(b)));
    });

    test('a large file hashes without special handling', () {
      // A 22-page statement is a megabyte or so. Nothing here chunks or
      // truncates, and a hash taken over the first N bytes would call
      // two statements identical whenever their first page matched.
      final big = Uint8List(1024 * 1024);
      for (var i = 0; i < big.length; i++) {
        big[i] = i % 251;
      }
      final same = Uint8List.fromList(big);
      final tweaked = Uint8List.fromList(big)..[big.length - 1] ^= 1;

      expect(contentHash(big), contentHash(same));
      // Changed in the LAST byte. A prefix hash would miss this.
      expect(contentHash(big), isNot(contentHash(tweaked)));
    });
  });
}

/// And what gets said when the same file turns up again.
///
/// The upload happens either way. An `attachments` row is not merely a
/// file — it carries `entity_table`, `entity_id` and `0708`'s evidence
/// lock — so handing this document somebody else's attachment would
/// re-file their paper against a record they did not choose. Telling
/// them costs one duplicate object; reusing silently could cost them
/// the audit trail.
void _duplicateSentence() {
  group('the sentence about a file that has been here before', () {
    test('names when it was filed, and what it was called', () {
      final said = alreadyHereNotice(
        fileName: 'maybank-august.pdf',
        filedAt: DateTime(2026, 8, 3),
      );

      expect(said, isNotNull);
      expect(said, contains('03/08/2026'));
      expect(said, contains('maybank-august.pdf'));
    });

    test('is a notice and not a refusal', () {
      // Somebody re-uploading because the first scan went badly is
      // doing a reasonable thing. The answer is a sentence.
      final said = alreadyHereNotice(
        fileName: 'x.pdf',
        filedAt: DateTime(2026, 8, 3),
      );

      expect(said, contains('kept again'));
      expect(said, isNot(contains('cannot')));
      expect(said, isNot(contains('refused')));
    });

    test('and says nothing at all when there is nothing to say', () {
      // A file genuinely new AND a file whose match predates `0711`
      // both arrive here as nulls, and they are indistinguishable from
      // here — which is exactly why this must never claim a document
      // IS new.
      expect(alreadyHereNotice(), isNull);
      expect(alreadyHereNotice(fileName: null, filedAt: null), isNull);
    });

    test('a date with no name still says the useful half', () {
      final said = alreadyHereNotice(filedAt: DateTime(2026, 1, 9));

      expect(said, isNotNull);
      expect(said, contains('09/01/2026'));
    });

    test('and a name with no date likewise', () {
      final said = alreadyHereNotice(fileName: 'rhb-oct.pdf');

      expect(said, isNotNull);
      expect(said, contains('rhb-oct.pdf'));
    });
  });
}
