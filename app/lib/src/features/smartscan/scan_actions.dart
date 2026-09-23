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

import '../../core/providers.dart';
import '../../data/ocr_repository.dart';
import '../shared/receipt_capture.dart';
import '../shared/scan_runner.dart';
import 'scan_availability.dart';
import 'scan_blocked_dialog.dart';
import 'scan_flow.dart';

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
}) {
  if (ocr == null) return const [];
  return [
    for (final p in ocr.providers)
      if (p.isActive &&
          p.ready &&
          !p.runsOnDevice &&
          (ocr.keySource != 'own' || ocr.keys.contains(p.code)) &&
          (!isPdf || p.readsPdf == true))
        p,
  ];
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
  final repo = ref.read(repoProvider);
  final attachmentId = entry.attachmentId;
  if (repo == null || attachmentId == null) return false;

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

  try {
    final read = provider == null
        // No choice made: whatever this company is set to, which is the
        // one path that can reach the on-device reader.
        ? await readDocument(
            ref,
            ocr: known ?? await ref.read(ocrStatusProvider.future),
            attachmentId: attachmentId,
            storagePath: entry.storagePath,
            mimeType: entry.mimeType,
          )
        // A reader named for this scan only. Straight to the server,
        // because `rescanChoices` never offers one that runs on the
        // device.
        : await repo.scanAttachment(attachmentId, provider: provider);

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
          : 'Could not read it again: $e'),
    ));
    return false;
  }
}
