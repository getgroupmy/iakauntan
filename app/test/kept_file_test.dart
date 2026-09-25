// Uploading a document and not reading it.
//
// `0714`. Asked for as "add an upload button where this button will
// upload file to storage and save it for later use", plus dropping a
// file in on the web.
//
// The part that is easy to get wrong is not the upload. It is that a
// file kept without a reading has NO `ocr_scans` row, so every sentence
// this screen writes about a row was written about a reading — and
// applied to a kept file each one of them says something untrue. "Not
// filed against anything yet" suggests a reading happened and led
// nowhere; "Read 25 Sep by gemini" names a reader that never saw it.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/data/attachments_repository.dart';
import 'package:iakauntan/src/data/ocr_repository.dart';
import 'package:iakauntan/src/features/shared/file_drop.dart';
import 'package:iakauntan/src/features/shared/receipt_capture.dart';
import 'package:iakauntan/src/features/smartscan/smartscan_screen.dart';

ScanInboxEntry _kept() => ScanInboxEntry(
      scanId: null,
      attachmentId: 'att-1',
      fileName: 'august-statement.pdf',
      scannedAt: DateTime(2026, 9, 25),
    );

void main() {
  group('a row with no scan behind it', () {
    test('is a kept file, and says so', () {
      expect(_kept().isKeptOnly, isTrue);
      expect(scanRowSubtitle(_kept()), 'Kept, not read yet');
    });

    test('and does not claim a reading led nowhere', () {
      // The sentence an unposted SCAN gets. Said about a kept file it
      // means "somebody read this and built nothing from it", which is
      // a different and wrong story.
      expect(scanRowSubtitle(_kept()), isNot(contains('Not filed against')));
    });

    test('a reading that became nothing still says its own sentence', () {
      final scanned = ScanInboxEntry(
        scanId: 's-1',
        attachmentId: 'att-2',
        fileName: 'bill.pdf',
        status: 'ok',
        scannedAt: DateTime(2026, 9, 25),
      );
      expect(scanned.isKeptOnly, isFalse);
      expect(scanRowSubtitle(scanned), 'Not filed against anything yet');
    });

    test('a kept file keeps its kind label when it has one', () {
      final e = ScanInboxEntry(
        scanId: null,
        attachmentId: 'att-3',
        fileName: 'x.pdf',
        kindLabel: 'Bank statement',
        scannedAt: DateTime(2026, 9, 25),
      );
      expect(scanRowSubtitle(e), 'Bank statement · Kept, not read yet');
    });
  });

  group('what the person is told after keeping one', () {
    test('it is safe, and it was NOT read', () {
      // Both halves matter. "Uploaded" on a screen called AI SmartScan
      // reads as "scanned" unless it is contradicted, and somebody who
      // thinks the figures are in will go looking for them.
      final m = keptFileMessage(const KeptFile(
        attachmentId: 'a',
        fileName: 'august.pdf',
      ));
      expect(m, contains('august.pdf'));
      expect(m, contains('kept'));
      expect(m, contains('not been read'));
    });

    test('and the same file twice is mentioned, not refused', () {
      final m = keptFileMessage(KeptFile(
        attachmentId: 'a',
        fileName: 'august.pdf',
        alreadyHere: Attachment(
          id: 'old',
          fileName: 'august-1.pdf',
          storagePath: 'p',
          createdAt: DateTime(2026, 8, 3),
        ),
      ));
      expect(m, contains('august-1.pdf'));
      // A notice beside the file, never a refusal: somebody re-uploads
      // a document for reasons they understand better than this system
      // does. `0711`.
      expect(m, contains('kept'));
      expect(m.toLowerCase(), isNot(contains('cannot')));
      expect(m.toLowerCase(), isNot(contains('refused')));
    });
  });

  group('the row an upload writes', () {
    final bytes = Uint8List.fromList([1, 2, 3, 4]);

    Map<String, dynamic> row({required bool keep}) => attachmentRow(
          orgId: 'org-1',
          table: 'expenses',
          recordId: 'rec-1',
          fileName: 'august.pdf',
          path: 'org-1/expenses/rec-1/august.pdf',
          bytes: bytes,
          mimeType: 'application/pdf',
          keepForLater: keep,
          now: DateTime.utc(2026, 9, 25, 12),
        );

    test('carries kept_at only when the file is being KEPT', () {
      // The single column that decides whether a file can be found
      // again: `scan_inbox` unions on it. Without it the bytes are in
      // the bucket and the document is visible nowhere in the product,
      // which is the failure the upload button exists to avoid.
      expect(row(keep: true)['kept_at'], '2026-09-25T12:00:00.000Z');
    });

    test('and leaves it off every other upload', () {
      // Absent rather than null, so an attachment filed against a bill
      // is exactly the row it was before 0714.
      expect(row(keep: false).containsKey('kept_at'), isFalse);
    });

    test('the rest of the row is the same either way', () {
      final kept = row(keep: true)..remove('kept_at');
      expect(kept, row(keep: false));
    });

    // A MUTANT THAT SURVIVES HERE, written down rather than left for
    // somebody to rediscover: `Repo.keepAttachment` delegating with
    // `keepForLater: false` instead of `true` cannot be caught by any
    // test in this file. It is a body inside `extension RepoAttachments
    // on Repo`, a Dart extension method binds to the STATIC type of its
    // receiver, and so a fake `Repo` is never called — the real body
    // runs against a live Supabase client. There is no seam.
    //
    // What can be done about it has been: the flag no longer appears at
    // any call site, only inside that one delegation, whose whole
    // reason for existing is to carry it. `attachmentRow` below is the
    // decision it feeds, and that IS asserted both ways.
    test('and the hash is still written on the way in', () {
      // `0711`. It cannot be recovered afterwards without downloading
      // the object back, so an upload that forgot it would leave a file
      // that can never be recognised as a duplicate.
      expect(row(keep: true)['content_sha256'], contentHash(bytes));
    });
  });

  group('dropping a file in', () {
    test('is not promised where it cannot happen', () {
      // Off the web this is the stub, and the screen reads it so that
      // "or drop one here" is never printed under a button on a phone,
      // where there is no pointer that can carry a file.
      expect(canDropFiles, isFalse);
    });

    test('and the stub hands back a stop function that is safe to call', () {
      // Every caller disposes the same way on every platform rather
      // than branching, so the no-op has to be callable.
      final stop = listenForDroppedFiles((_) {});
      expect(stop, isA<void Function()>());
      stop();
    });
  });
}
