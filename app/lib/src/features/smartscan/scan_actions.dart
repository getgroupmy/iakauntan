/// What can still be done with a scan that has already happened.
///
/// The detail sheet was a read-only account of one reading: what was
/// filled in, which column each field went to, and what the paper
/// became. Three things were missing from it, and all three were asked
/// for while looking at a scan that had come back wrong:
///
///   * CREATE THE RECORD FROM WHAT WAS READ. The reading is on the row
///     and nothing was ever built from it, so the figures were on
///     screen and the only way to use them was to type them in again.
///   * READ IT AGAIN. A vendor has bad afternoons; `459d3716` retries
///     once inside a single invocation, and after that the scan is
///     written off with no way to ask twice.
///   * READ IT WITH ANOTHER READER. Which is the one that matters: a
///     reader that refused a PDF, or made `Page 1 of 2` out of a
///     supplier name, is not going to do better on the second try.
///
/// The pure parts are separated from the ones that need a `context`,
/// because the interesting judgement here — which readers may be
/// offered for THIS file — is a table of cases and belongs in a test
/// rather than behind three taps.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/error_text.dart';
import '../../core/providers.dart';
import '../../data/ocr_repository.dart';
import '../shared/receipt_capture.dart';
import '../shared/scan_progress.dart';
import '../shared/scan_runner.dart';
import 'scan_availability.dart';
import 'scan_blocked_dialog.dart';
import 'scan_flow.dart';

/// Whether this scan's file is a PDF.
///
/// By the declared type, and by the NAME when there is no declared
/// type — which there often is not. `attachments.mime_type` is
/// whatever the picker supplied at upload, and a file chosen in a
/// browser frequently arrives with none at all. The first report of
/// this feature showed the menu offering Gemini for a file called
/// `5646539013.pdf`, because the column was null and the question had
/// only ever been asked of the column.
///
/// The bytes are not available here — this is a row out of
/// `scan_inbox`, not a file in hand — so this is the weaker half of
/// [looksLikePdf], which sniffs the first four bytes. A file with a
/// misleading name and no type still reaches the reader and is refused
/// there, which is the backstop either way.
bool scanIsPdf(ScanInboxEntry entry) =>
    entry.mimeType == 'application/pdf' ||
    (entry.fileName ?? '').toLowerCase().trimRight().endsWith('.pdf');

/// The readers this company could send this file to, right now.
///
/// Not "every reader on the catalog". Four things take one off the
/// list, and each of them is a scan somebody would otherwise pay for
/// to be told no:
///
///   * the platform has RETIRED it, or has not finished setting it up
///     (`ready`) — `ocr_status` sends both, and `set_ocr_settings`
///     refuses on the same test;
///   * it runs ON THE DEVICE, and this is the server path. The
///     on-device reader is reached by "read it again" on a company
///     that is set to it, not by choosing it here;
///   * the company brings its OWN KEY and has none for that reader.
///     `ocr_begin` refuses this and would be right to; offering it
///     first is the screen setting somebody up;
///   * it CANNOT OPEN THIS FILE. `0697` put that on the wire as
///     `reads_pdf`, and a PDF handed to a chat-completions reader is
///     refused by name in the edge function after the charge is taken.
///
/// [isPdf] rather than a mime type, because the caller knows the file
/// and this stays a question about readers.
///
/// An unknown answer (`readsPdf == null`) counts as NO for a PDF, and
/// that is the opposite of what [pdfBlock] does with the same value —
/// on purpose, and the two are not in disagreement. [pdfBlock] decides
/// whether to REFUSE, where an unknown must not withdraw a reader the
/// platform has just added. This decides what to OFFER, and every name
/// on this list is a promise that pressing it will read this file.
/// [pdfReaders] draws the same line for the same reason.
///
/// A mutant that swapped it survived the first sweep, which is what
/// found the two functions disagreeing.
List<OcrProvider> rescanChoices(
  OcrSettings? ocr, {
  required bool isPdf,
  required bool deviceReaderHere,
  required bool deviceReadsPdf,
}) {
  if (ocr == null) return const [];
  return [
    for (final p in ocr.providers)
      if (_offerable(p, ocr,
          isPdf: isPdf,
          deviceReaderHere: deviceReaderHere,
          deviceReadsPdf: deviceReadsPdf))
        p,
  ];
}

/// One reader, one answer. Separated from the comprehension because the
/// two branches ask genuinely different questions and reading them
/// nested inside a list literal is how the on-device case came to be a
/// bare `!p.runsOnDevice` in the first place.
bool _offerable(
  OcrProvider p,
  OcrSettings ocr, {
  required bool isPdf,
  required bool deviceReaderHere,
  required bool deviceReadsPdf,
}) {
  // The platform's two answers, and they apply to every reader: one it
  // has retired, and one it has not finished setting up.
  if (!p.isActive || !p.ready) return false;

  if (p.runsOnDevice) {
    // `0700`. Left off this list until then, because `ocr_begin`
    // refuses a device reader — which was building the list out of
    // what the SERVER would accept rather than out of what can read
    // the file. The app reads it here, with no key and no charge.
    //
    // Two conditions of its own, and neither is a question about the
    // catalog, which is why both arrive as arguments. It has to have
    // LOADED — on the web that is a script that may not have arrived —
    // and it has to be able to open a PDF, which is `pdf.js` in a
    // browser and not ML Kit on a phone.
    return deviceReaderHere && (!isPdf || deviceReadsPdf);
  }

  // A server reader the company has no key for, when the company is
  // the one holding the keys. `ocr_begin` refuses this and would be
  // right to; offering it first is the screen setting somebody up.
  if (ocr.keySource == 'own' && !ocr.keys.contains(p.code)) return false;

  return !isPdf || p.readsPdf == true;
}


/// What the button for one reader says about what it will cost.
///
/// A rescan on a chargeable reader SPENDS CREDIT, and on a company
/// whose own reader is free that is a surprise worth heading off — the
/// price is on the choice rather than in a sentence underneath it,
/// because a person reads the thing they are about to press.
///
/// `own` never shows a price: the company is paying its vendor
/// directly and the platform takes nothing.
String rescanCost(OcrProvider reader, OcrSettings ocr) {
  if (ocr.keySource == 'own' || reader.price <= 0) return 'No charge';
  return 'RM ${reader.price.toStringAsFixed(2)}';
}

/// Whether reading this one again is worth offering at all.
///
/// Null when it is. A sentence when it is not, and the sentence is the
/// honest one rather than a disabled button somebody stares at.
String? rescanRefusal(ScanInboxEntry entry) {
  if (entry.attachmentId == null || (entry.storagePath ?? '').isEmpty) {
    // The document this was filed against has been deleted, which
    // deletes the attachment — `ocr_scans.attachment_id` is `on delete
    // set null`. There is no file left to read.
    return 'The file this was read from has been deleted, so there is '
        'nothing left to read again.';
  }
  return null;
}

/// Build the record this reading describes, from the reading.
///
/// Goes through the same door a fresh capture does — the destination is
/// decided, a contact is found or created, the record is made, the
/// capture is re-pointed at it and the scan is marked with what it
/// became. Nothing here is a second implementation of that; it is the
/// same flow entered one step in, because the photograph already
/// happened.
Future<void> createFromScan(
  BuildContext context,
  WidgetRef ref,
  ScanInboxEntry entry,
  OcrExtraction read,
) async {
  final attachmentId = entry.attachmentId;
  if (attachmentId == null) return;
  await sendScanOn(
    context,
    ref,
    // `placeholderId` is what a FRESH capture parks itself against
    // until the record exists. This file was parked and filed long
    // ago, so there is no placeholder — and nothing downstream reads
    // the field. Passing the attachment id keeps it non-null and
    // truthful about which object it is, rather than inventing a uuid
    // that names nothing.
    StagedReceipt(
      attachmentId: attachmentId,
      placeholderId: attachmentId,
      read: read,
    ),
  );
}

/// Read the same file again, optionally with a reader of somebody's
/// choosing.
///
/// Returns true when a reading came back, so the caller can refresh
/// rather than guess.
///
/// [provider] null means "the way this company is set up", which is the
/// only route to the on-device reader: an org on ML Kit reads it again
/// on this device, and the server is not involved.
Future<bool> rescanDocument(
  BuildContext context,
  WidgetRef ref,
  ScanInboxEntry entry, {
  String? provider,
}) async {
  final attachmentId = entry.attachmentId;
  if (ref.read(repoProvider) == null || attachmentId == null) return false;

  final messenger = ScaffoldMessenger.of(context);

  // The same prediction the capture path makes, for the same reason:
  // the module being off, or scanning being switched off, is knowable
  // before anything is spent. Caught, because a status call that will
  // not answer must not lose the press.
  OcrSettings? known;
  try {
    known = await ref.read(ocrStatusProvider.future);
  } catch (_) {
    known = null;
  }
  if (!context.mounted) return false;

  final block = scanBlock(known, canAdmin: ref.read(canAdminProvider));
  if (block != null) {
    await showScanBlocked(context, block);
    return false;
  }

  final OcrSettings settings =
      known ?? await ref.read(ocrStatusProvider.future);
  // That `??` hides an await, and the modal below is opened on this
  // context. A screen that went away while the status was being asked
  // for is a screen with no navigator to open a dialog on.
  if (!context.mounted) return false;

  // Whether the reader somebody picked is this machine. `0700`. Read
  // off the catalog rather than compared against `'mlkit'`, because a
  // platform may stand up a second on-device engine and the literal
  // would silently send it to the server.
  final chosen = provider == null
      ? null
      : settings.providers.where((p) => p.code == provider).firstOrNull;
  final locally = provider == null ? null : chosen?.runsOnDevice ?? false;

  try {
    // One call either way. `readDocument` owns the on-device path
    // entirely — the refusals, the PDF branch and `recordLocalScan` —
    // so asking it to read here is a parameter rather than a second
    // implementation of all of that.
    //
    // `onDevice: null` means the company's setting decides, which is
    // what "Read it again" does and the only way an org set to Local
    // Read reaches its own reader.
    // Behind the same modal a fresh capture gets, starting at the
    // reading step because there is nothing to upload — the file has
    // been in the bucket since the first scan. What it blocks here is
    // a second "Read it again" landing on top of the first, which is
    // two charges for one document.
    final read = await whileScanning<OcrExtraction>(
      context,
      from: ScanStage.reading,
      action: (report) => readDocument(
        ref,
        ocr: settings,
        attachmentId: attachmentId,
        storagePath: entry.storagePath,
        // The name as well as the declared type: a file picked in a
        // browser often carries no type at all, and the on-device path
        // has to know a PDF from a photograph to choose its engine.
        mimeType: entry.mimeType ??
            (scanIsPdf(entry) ? 'application/pdf' : null),
        onDevice: locally,
        provider: locally == true ? null : provider,
        onLocalFallback: () => report(ScanStage.readingHere),
      ),
    );

    // The balance moved and a new scan row exists, so everything
    // drawn off either has to be asked again.
    ref.invalidate(ocrStatusProvider);
    if (context.mounted) {
      messenger.showSnackBar(SnackBar(
        content: Text(read.supplierName == null
            ? 'Read again. Check what it found.'
            : 'Read again: ${read.supplierName}'),
      ));
    }
    return true;
  } catch (e) {
    ref.invalidate(ocrStatusProvider);
    messenger.showSnackBar(SnackBar(
      content: Text(e is OcrException
          ? e.message
          : 'Could not read it again: ${errorText(e)}'),
    ));
    return false;
  }
}
