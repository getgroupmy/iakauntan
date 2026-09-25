import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show StorageException;

import '../../core/providers.dart';
import '../../data/attachments_repository.dart';
import '../../data/ocr_repository.dart';
import '../../data/repository.dart';
import 'text_reader.dart';
import 'receipt_text.dart';

/// Whether this is a PDF, by what it *is* as well as by what it says
/// it is.
///
/// A file picked in a browser does not always carry a type, and a PDF
/// that arrives unlabelled otherwise reaches the picture reader and
/// comes back "Error attempting to read image" — which sends somebody
/// looking at the photograph rather than at the format.
///
/// Public and shared since `0697`, because the question is now asked
/// twice: once here, where the on-device reader refuses one, and once
/// before the upload, where the app predicts a server reader refusing
/// one. Two copies of a magic-number check would be two chances for
/// the two answers to differ, and the whole point of the second is
/// that it agrees with the first.
bool looksLikePdf(String? mimeType, Uint8List? bytes) =>
    mimeType == 'application/pdf' ||
    (bytes != null &&
        bytes.length >= 4 &&
        bytes[0] == 0x25 && // %
        bytes[1] == 0x50 && // P
        bytes[2] == 0x44 && // D
        bytes[3] == 0x46); //  F

/// Whether a server reading that failed is worth trying HERE instead.
///
/// Asked for in one sentence: "when the ai model is not reachable it
/// should read with local". `0679` already retries a failed scan on the
/// platform's free reader, and `ocr_fallback` deliberately excludes the
/// on-device one — `and not p.runs_on_device` — because the edge
/// function cannot run it: the file would have to travel back to the
/// machine that sent it. So this decision is the app's, and only the
/// app's.
///
/// ## Why a status and not a sentence
///
/// The rule is `retry.ts`'s, and it is the one both vendors document:
/// 408, 409, 429 and any 5xx are the reader saying "not now". A 502 is
/// what the edge function answers when the vendor would not read the
/// document at all, which is the case this was asked for.
///
/// Everything else is a statement about THIS request that reading it
/// here would circumvent rather than rescue: a 402 is no credit left,
/// a 403 is scanning switched off or the module lapsed, a 413 is a file
/// too big. A company that has switched scanning off has switched it
/// off, and a free reader on the phone is not the exception to that —
/// `ocr_record_local` refuses it anyway, which is the backstop, but
/// asking is the thing that would be wrong.
///
/// [failure] with no status at all is treated as unreachable, and that
/// is the deliberate half. Nothing answered: no `FunctionException`, so
/// no code — a dead connection, a DNS failure, a request that never
/// left an aeroplane. That is the plainest reading of "not reachable"
/// there is. The one exception is an [OcrException] the function
/// returned in a 200 body, which DID answer and is carrying a refusal.
bool readerUnreachable(Object failure) {
  if (failure is! OcrException) return true;
  final status = failure.status;
  if (status == null) return false;
  if (status == 408 || status == 409 || status == 429) return true;
  return status >= 500 && status <= 599;
}

/// Whether this machine could read the file, if it were asked to.
///
/// The same three questions [readDocument] asks on its way into the
/// on-device path, asked BEFORE the fallback rather than inside it —
/// because failing in there writes a scan row saying the phone cannot
/// open a PDF, against a document nobody asked the phone to read.
bool canReadHere({
  required bool isPdf,
  required bool haveFile,
  bool? readerHere,
  bool? readsPdf,
}) =>
    (readerHere ?? onDeviceReaderAvailable) &&
    haveFile &&
    (!isPdf || (readsPdf ?? onDeviceReadsPdf));

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
///
/// Since `0703` the server path falls through to the local one when the
/// reader would not answer and this machine could have read it — see
/// [readerUnreachable] for what counts. Silently, and on purpose: the
/// person gets the reading they asked for, and the SCAN ROW says which
/// reader produced it, which is where that belongs. The server's own
/// failed row is written and refunded by the edge function before this
/// ever sees the error.
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

  /// Read HERE, or on the server, whatever this company is set to.
  /// `0700`. Null means the setting decides, which is every caller
  /// written before "Read it with" existed.
  bool? onDevice,

  /// A server reader named for this one document. `0698`. Ignored on
  /// the on-device path, which has exactly one engine per platform.
  String? provider,

  /// Called when the server reader would not answer and this machine
  /// is about to have a go instead.
  ///
  /// For the progress dialog, and for nothing else: the fallback is
  /// silent as far as the RESULT is concerned — what came back is a
  /// reading either way, and which reader made it is on the scan row.
  /// What this is for is the wait, which just got longer, and a modal
  /// that goes on saying "Reading the document" through it is a modal
  /// that looks stuck.
  void Function()? onLocalFallback,

  /// The destination this document is already known to have, as
  /// `module.action`.
  ///
  /// Only the server reader is told: the on-device engine has no
  /// schema to narrow and reads what it reads. See
  /// `Repo.scanAttachment`.
  String? target,
}) async {
  final repo = ref.read(repoProvider)!;
  // `0700`. The company's setting decides by default, and a caller can
  // override it for ONE document — which is what "Read it with → Local
  // Read" is. The override has to be here rather than at the call site,
  // because everything below this line is the on-device path: the
  // refusals, the PDF branch, and `recordLocalScan`.
  if (!(onDevice ?? ocr.onDevice)) {
    try {
      return await repo.scanAttachment(attachmentId,
          provider: provider, target: target);
    } catch (e) {
      if (!readerUnreachable(e) ||
          !canReadHere(
            isPdf: looksLikePdf(mimeType, localBytes),
            haveFile: localPath != null ||
                localBytes != null ||
                (storagePath ?? '').isNotEmpty,
          )) {
        rethrow;
      }
      onLocalFallback?.call();
      try {
        return await _readHere(
          repo,
          attachmentId: attachmentId,
          mimeType: mimeType,
          storagePath: storagePath,
          localPath: localPath,
          localBytes: localBytes,
        );
      } catch (_) {
        // The rescue failed too. What the person is told is what they
        // ASKED for — the reader they chose, and the reference the
        // edge function minted for it, which is the one somebody can
        // quote. The local failure is on its own scan row, written by
        // `_readHere` on its way out.
        // ignore: use_rethrow_when_possible
        throw e;
      }
    }
  }

  return _readHere(
    repo,
    attachmentId: attachmentId,
    mimeType: mimeType,
    storagePath: storagePath,
    localPath: localPath,
    localBytes: localBytes,
  );
}

/// The reading that happens on this machine, and the row it leaves.
///
/// Split out of [readDocument] by `0703` so the fallback is the same
/// code as the deliberate choice rather than a second copy of it. Every
/// refusal in here is about THIS MACHINE — no reader loaded, a PDF on a
/// phone, no file to read — which is why the fallback asks
/// [canReadHere] first and never reaches them.
Future<OcrExtraction> _readHere(
  Repo repo, {
  required String attachmentId,
  String? mimeType,
  String? storagePath,
  String? localPath,
  Uint8List? localBytes,
}) async {
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
  final isPdf = looksLikePdf(mimeType, localBytes);

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
    // A missing object is the commonest of these and the least
    // actionable, and it used to arrive as a Dart toString of a JSON
    // body. `storageProblem` says what is true instead.
    if (e is StorageException) throw OcrException(storageProblem(e));
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
