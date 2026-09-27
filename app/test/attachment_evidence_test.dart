import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/data/attachments_repository.dart';

/// Two things about a file that was uploaded.
///
///     all uploded documents should be saved in record no matter it was
///     used or not / if used and attached it csnt be deleted but if not
///     used and attached it's to have option to delete
///
///     when the file is uploaded it should also add date and time in
///     the filename
///
/// The rule about deleting is in the database — `0708`, asserted by
/// `supabase/tests/attachment_is_evidence.sql`, because a button the
/// app declines to draw is not a rule. What is here is the half the app
/// owns: the name a file is stored under, and whether the row that
/// comes back knows it is evidence.
void main() {
  final when = DateTime(2026, 9, 24, 17, 10);

  group('the name a file is stored under', () {
    test('carries the day and the minute it arrived', () {
      expect(stampedFileName('5665871390.pdf', when),
          '5665871390_20260924-1710.pdf');
    });

    test('and the extension stays last', () {
      // What every operating system opens the file by. A stamp after
      // the suffix produces something nothing will open.
      expect(stampedFileName('bil.PDF', when).endsWith('.PDF'), isTrue);
    });

    test('a name with several dots splits at the last one', () {
      expect(stampedFileName('invois.2026.09.pdf', when),
          'invois.2026.09_20260924-1710.pdf');
    });

    test('a name with no extension is stamped at the end', () {
      expect(stampedFileName('scan', when), 'scan_20260924-1710');
    });

    test('a hidden file is not split at its leading dot', () {
      // `.gitignore` is a name, not an empty name with an extension.
      expect(stampedFileName('.gitignore', when),
          '.gitignore_20260924-1710');
    });

    test('a trailing dot is a typo, not an extension', () {
      expect(stampedFileName('bil.', when), 'bil._20260924-1710');
    });

    test('an empty name still gets one', () {
      expect(stampedFileName('   ', when), 'file_20260924-1710');
    });

    test('single digits are padded, so the names sort', () {
      // The whole reason for this shape rather than 24-9-2026 5:10pm:
      // a folder of them has to sort into the order they arrived.
      expect(stampedFileName('a.pdf', DateTime(2026, 1, 2, 3, 4)),
          'a_20260102-0304.pdf');
    });

    test('two files of the same name are told apart', () {
      final first = stampedFileName('invoice.pdf', DateTime(2026, 9, 24, 9, 1));
      final second =
          stampedFileName('invoice.pdf', DateTime(2026, 9, 24, 17, 10));
      expect(first, isNot(second));
      expect(first.compareTo(second) < 0, isTrue);
    });
  });

  group('what the row says about itself', () {
    test('a file a posting was built from knows it stays', () {
      final a = Attachment.fromJson({
        'id': 'a-1',
        'file_name': 'bil_20260924-1710.pdf',
        'storage_path': 'org/purchase_documents/doc/bil.pdf',
        'created_at': '2026-09-24T17:10:00Z',
        'is_evidence': true,
      });
      expect(a.isEvidence, isTrue);
    });

    test('and a spare copy knows it can go', () {
      final a = Attachment.fromJson({
        'id': 'a-2',
        'file_name': 'dua.pdf',
        'storage_path': 'org/purchase_documents/doc/dua.pdf',
        'created_at': '2026-09-24T17:10:00Z',
        'is_evidence': false,
      });
      expect(a.isEvidence, isFalse);
    });

    test('a row from a caller that did not ask is not treated as locked',
        () {
      // `false` rather than `true`: the trigger refuses either way, and
      // a lock drawn on a file nobody asked about is a file somebody
      // cannot remove and cannot be told why.
      final a = Attachment.fromJson({
        'id': 'a-3',
        'file_name': 'tiga.pdf',
        'storage_path': 'org/purchase_documents/doc/tiga.pdf',
        'created_at': '2026-09-24T17:10:00Z',
      });
      expect(a.isEvidence, isFalse);
    });
  });
}
