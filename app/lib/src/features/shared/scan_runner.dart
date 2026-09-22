import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../data/attachments_repository.dart';
import '../../data/ocr_repository.dart';
import 'text_reader.dart';
import 'receipt_text.dart';

/// Reads one filed document, whichever reader the organization chose.
///
/// The two paths behind this are not variations on each other. The
/// paid readers happen in an edge function: the charge is taken before
/// the provider is called and returned if it fails, and the app only
/// ever sees the answer. The free one happens here — ML Kit on a phone,
/// Tesseract in a browser — so the file never leaves the machine, and
/// the log is written afterwards rather than around it, because there
/// is no money to protect and nothing to refund.
///
/// Both callers go through this, so neither has to know which reader is
/// in force and the on-device path cannot quietly stop logging.
Future<OcrExtraction> readDocument(
  WidgetRef ref, {
  required OcrSettings ocr,
  required String attachmentId,
  String? mimeType,

  /// Where the file lives in the bucket. Only needed when neither
  /// [localPath] nor [localBytes] is given — reading a document filed
  /// some time ago rather than one just captured.
  String? storagePath,

  /// The file on this device, when it is a file. A receipt just
  /// photographed on a phone has a path, and fetching a copy of it back
  /// out of storage to read it would be silly.
  String? localPath,

  /// The file in memory, which is what a capture in a *browser* has —
  /// there is no path there, only bytes. This being absent is why the
  /// first web scan went looking in storage with an empty key.
  Uint8List? localBytes,
}) async {
  final repo = ref.read(repoProvider)!;
  if (!ocr.onDevice) return repo.scanAttachment(attachmentId);

  if (!onDeviceReaderAvailable) {
    throw OcrException(
      'The on-device reader did not load. Reload the page, or switch to '
      'a reader that runs on the server in Settings.',
    );
  }

  // Neither on-device engine opens a PDF: ML Kit takes an image and
  // Tesseract takes a bitmap. Refused by name rather than handed over to
  // fail as "nothing legible", which would send somebody looking at the
  // photograph instead of at the format.
  // Recognised by what it *is* as well as by what it says it is. A file
  // picked in a browser does not always carry a type, and a PDF that
  // arrives unlabelled otherwise reaches the picture reader and comes
  // back "Error attempting to read image" — which sends somebody looking
  // at the photograph rather than at the format.
  final isPdf = mimeType == 'application/pdf' ||
      (localBytes != null &&
          localBytes.length >= 4 &&
          localBytes[0] == 0x25 && // %
          localBytes[1] == 0x50 && // P
          localBytes[2] == 0x44 && // D
          localBytes[3] == 0x46); //  F

  // A browser reads a PDF; a phone does not. Said plainly on the side
  // that cannot, because "photograph the page" is a real instruction
  // there — the camera is already in your hand.
  if (isPdf && !onDeviceReadsPdf) {
    throw OcrException(
      'The reader on this phone takes photographs, not PDFs. Photograph '
      'the page, open the bill on a computer, or use a reader that runs '
      'on the server.',
    );
  }

  // The bytes, from wherever they already are. Going back to the bucket
  // for a file that is in memory is a round trip for nothing, and doing
  // it with no key is a 400 that reads as though the reader broke.
  if (localPath == null &&
      localBytes == null &&
      (storagePath == null || storagePath.isEmpty)) {
    throw OcrException(
      'There is nothing to read: no file was given and none is on record.',
    );
  }

  try {
    // A PDF is always read from its bytes: `pdf.js` parses a document
    // rather than opening a file, and on the one platform that reads
    // PDFs there are no file paths to open anyway.
    final text = isPdf
        ? await readTextFromPdfBytes(
            localBytes ?? await repo.attachmentBytes(storagePath!))
        : localPath != null
            ? await readTextFromFile(localPath)
            : await readTextFromBytes(
                localBytes ?? await repo.attachmentBytes(storagePath!));

    final read = parseReceiptText(text);
    // Logged whether or not much came back. "Why is this figure blank"
    // and "why was nothing read" are the same question asked twice, and
    // the row is what answers both.
    await repo.recordLocalScan(attachmentId: attachmentId, read: read);
    return read;
  } catch (e) {
    // Best effort: a reading that failed is worth recording, but a
    // failure to record it must not replace the error that caused it.
    try {
      await repo.recordLocalScan(
          attachmentId: attachmentId, error: e.toString());
    } catch (_) {}
    if (e is OcrException) rethrow;
    throw OcrException('Could not read it on this device: $e');
  }
}

/// Files the scan behind [attachmentId] as whatever kind of document
/// the person settled on.
///
/// `0614`. Called after the scan result dialog closes, by whoever has
/// the attachment in hand — the dialog is handed a reading and nothing
/// else, so it cannot do this itself.
///
/// Best effort on purpose. This is a note about a reading, and a bill
/// that was read and corrected must not be lost because the note would
/// not write: the form has the figures either way, and a scan with no
/// kind on it is what every reading before 0614 looks like.
Future<void> rememberDocumentKind(
  WidgetRef ref, {
  required String attachmentId,
  required OcrExtraction accepted,
}) async {
  final kind = accepted.documentKind;
  if (kind == null) return;
  try {
    await ref
        .read(repoProvider)
        ?.setScanDocumentKind(attachmentId: attachmentId, kind: kind);
  } catch (_) {
    // Deliberately swallowed; see above.
  }
}

/// Files what the person accepted, and what they changed on the way.
///
/// `0684`. The correction is the only ground truth this system
/// produces: somebody holding the paper, looking at the reading beside
/// it, putting a figure right. It arrives free and was dropped on the
/// floor, which left every question about which reader is better --
/// and whether a cheaper one is actually cheaper -- unanswerable.
///
/// Called unconditionally, including when nothing was changed. A
/// reading accepted as it stands is the reader being RIGHT, and that is
/// the datum the count is built on; recording only the corrections
/// would give a denominator of nothing.
///
/// Best effort, for the same reason `rememberDocumentKind` is: this is
/// a note about a reading, and a bill that was read and corrected must
/// not be lost because the note would not write.
Future<void> rememberCorrection(
  WidgetRef ref, {
  required String attachmentId,
  required OcrExtraction accepted,
}) async {
  try {
    await ref
        .read(repoProvider)
        ?.noteScanCorrection(attachmentId: attachmentId, accepted: accepted);
  } catch (_) {
    // Deliberately swallowed; see above.
  }
}
