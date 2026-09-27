import 'package:iakauntan/src/data/ocr_repository.dart';
import 'package:flutter_test/flutter_test.dart';

/// The file behind a scan stays until somebody removes it.
///
///     Why can't read again / the image / pdf / file should be
///     available till it's deleted or attached to documents
///
/// Reported from the inbox: a document photographed at 19:33, read by
/// Gemini, its supplier and number and date all on screen — and "View
/// the image" and "Read it again" both dead, because the file had been
/// deleted out from under them.
///
/// Two lines in `scan_flow.dart` did it. Backing out of "what is this?"
/// removed the capture, on the reasoning that a file attached to a
/// record that will never exist should not sit in the bucket. But
/// somebody who photographs a document and then closes a sheet has not
/// said "destroy this", and the READING was already paid for — so what
/// was left was a scan row pointing at nothing, which is the one state
/// that cannot be recovered from.
///
/// Both are gone. What decides the button is here.
void main() {
  ScanInboxEntry entry({
    String? path = 'org/expenses/x/IMG_7614_20260924-1933.jpeg',
    String? attachment = 'att-1',
    String? postedId,
  }) =>
      ScanInboxEntry(
        scanId: 's-1',
        scannedAt: DateTime(2026, 9, 24, 19, 33),
        provider: 'gemini',
        status: 'ok',
        attachmentId: attachment,
        storagePath: path,
        fileName: 'IMG_7614_20260924-1933.jpeg',
        postedId: postedId,
        postedTable: postedId == null ? null : 'expenses',
      );

  group('whether there is a file to remove', () {
    test('a capture nobody built anything from can be removed', () {
      final e = entry();
      expect(e.hasImage, isTrue);
      expect(e.becameSomething, isFalse);
      expect(e.fileCanBeRemoved, isTrue);
    });

    test('one that became a record cannot', () {
      // The evidence behind a posting. `0708` refuses the delete in the
      // database whatever this says; not drawing the button is so
      // nobody presses one that cannot work.
      final e = entry(postedId: 'exp-1');
      expect(e.becameSomething, isTrue);
      expect(e.fileCanBeRemoved, isFalse);
    });

    test('and one whose file is already gone offers nothing', () {
      // The reported state. The reading stays readable — `0697` made
      // the inbox survive a missing file — but there is nothing left to
      // remove, to open, or to read again.
      final e = entry(path: null, attachment: null);
      expect(e.hasImage, isFalse);
      expect(e.fileCanBeRemoved, isFalse);
    });

    test('a row with a path but no attachment is not a file', () {
      // `ocr_scans.attachment_id` is `on delete set null`, so the scan
      // keeps its own record of where it read the file after the
      // attachment has gone. That path is history, not a live object.
      expect(entry(attachment: null).hasImage, isFalse);
      expect(entry(attachment: null).fileCanBeRemoved, isFalse);
    });

    test('an empty path is not a file either', () {
      expect(entry(path: '').hasImage, isFalse);
    });
  });
}
