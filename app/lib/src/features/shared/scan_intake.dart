import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../data/attachments_repository.dart';
import '../../data/ocr_repository.dart';
import 'doc_scanner.dart';
import 'receipt_capture.dart';
import 'scan_result_dialog.dart';
import 'scan_runner.dart';

/// Start from the paper.
///
/// The ordinary way an expense happens is that somebody is holding a
/// receipt. Every screen here used to begin from the other end — open a
/// blank form, then find the paper — so this is the door that matches
/// the work: photograph it, see what was read, and finish only the parts
/// the document could not supply.
///
/// Three steps, and the middle one is not a formality. What a reader
/// makes of a faded thermal receipt is a first draft; it goes on screen
/// beside the fields it is about to fill, and it takes a press to accept
/// it. A figure the reader could not find is shown as *absent* rather
/// than as zero, which is the difference between "check this" and a
/// wrong number nobody looked at.
///
/// Returns null if the capture was cancelled, the reading was rejected,
/// or nothing legible came back.
Future<StagedReceipt?> showScanIntake(
  BuildContext context,
  WidgetRef ref, {
  /// Which table the capture is parked against until the record it
  /// belongs to exists.
  required String table,
  required String title,
}) async {
  final source = await _askSource(context, title);
  if (source == null || !context.mounted) return null;

  final staged = await captureAndRead(context, ref,
      source: source, table: table);
  if (staged == null || !context.mounted) return staged;

  // Nothing read, but a file worth keeping: hand it back so it is still
  // filed against whatever gets created, and let the form be typed in.
  if (staged.read == null) return staged;

  // The corrected reading, not the original one — the whole point of
  // showing it is that somebody may put a figure right.
  final accepted = await showScanResult(context, staged.read!, canApply: true);
  if (accepted != null) {
    // What the paper was taken to be, onto the scan. `0614`. Before the
    // return, because the caller is about to go and build a document
    // and this is a note about the reading rather than part of it.
    await rememberDocumentKind(ref,
        attachmentId: staged.attachmentId, accepted: accepted);
    // And what they changed. `0684`. Beside the kind because it is the
    // same sort of note -- a person's opinion about a reading -- and
    // because this is the last place that holds BOTH the reading and
    // the attachment it belongs to.
    await rememberCorrection(ref,
        attachmentId: staged.attachmentId, accepted: accepted);
    return StagedReceipt(
      attachmentId: staged.attachmentId,
      placeholderId: staged.placeholderId,
      read: accepted,
    );
  }

  // Discarded, and that means the whole thing.
  //
  // It used to mean only the *reading* was rejected: the capture was
  // handed back, the next screen asked which supplier it was for, and
  // somebody who had already decided to abandon this had to abandon it
  // twice. Discard is the button people press to get out, so it gets
  // them out — the parked capture goes with it rather than sitting in
  // the bucket attached to a document that will never exist.
  await ref.read(repoProvider)?.deleteAttachmentById(staged.attachmentId);
  return null;
}

/// Upload, photograph, or scan.
///
/// A sheet rather than a menu: on a phone this is the first thing after
/// a deliberate tap, and the three options are the three physical
/// situations somebody is in — the file is already on the device, the
/// paper is in their hand, or the paper is on the desk in front of them.
Future<CaptureSource?> _askSource(BuildContext context, String title) {
  return showModalBottomSheet<CaptureSource>(
    context: context,
    showDragHandle: true,
    builder: (context) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(Space.lg, 0, Space.lg, Space.sm),
            child: Text(title,
                style: Theme.of(context).textTheme.titleMedium),
          ),
          if (docScannerLikely)
            _SourceTile(
              icon: Icons.document_scanner_outlined,
              title: 'Scan the document',
              subtitle:
                  'Finds the edges and straightens it, which reads best',
              onTap: () => Navigator.pop(context, CaptureSource.scanner),
            ),
          if (cameraLikely)
            _SourceTile(
              icon: Icons.photo_camera_outlined,
              title: 'Take a photo',
              subtitle: 'The plain camera, for anything the scanner refuses',
              onTap: () => Navigator.pop(context, CaptureSource.camera),
            ),
          _SourceTile(
            icon: Icons.upload_file_outlined,
            title: 'Upload a file',
            subtitle: 'A photograph or a PDF you already have',
            onTap: () => Navigator.pop(context, CaptureSource.file),
          ),
          const SizedBox(height: Space.md),
        ],
      ),
    ),
  );
}

class _SourceTile extends StatelessWidget {
  const _SourceTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => ListTile(
        leading: Icon(icon),
        title: Text(title),
        subtitle: Text(subtitle, style: const TextStyle(fontSize: 12)),
        onTap: onTap,
      );
}

/// A reading waiting for the screen that will use it.
///
/// The purchase editor is reached by navigating, not by a constructor,
/// so the extraction cannot be handed over as an argument. It is parked
/// here and taken exactly once — `take()` clears it, so returning to the
/// same bill later does not re-apply a scan over work done since.
final pendingScanProvider =
    NotifierProvider<PendingScan, ({String documentId, OcrExtraction read})?>(
        PendingScan.new);

class PendingScan
    extends Notifier<({String documentId, OcrExtraction read})?> {
  @override
  ({String documentId, OcrExtraction read})? build() => null;

  void park(String documentId, OcrExtraction read) =>
      state = (documentId: documentId, read: read);

  /// The reading for this document, if one is waiting. Consumed.
  OcrExtraction? take(String documentId) {
    final held = state;
    if (held == null || held.documentId != documentId) return null;
    state = null;
    return held.read;
  }
}

/// A statement photographed on the way to the import screen.
///
/// `0694`. The reconciliation screen used to own its own scan button,
/// so the capture and the importer were on the same screen and the
/// reading could be handed straight over. With one door the two are a
/// navigation apart, and a route cannot carry an `OcrExtraction`.
///
/// Taken exactly once — `take()` clears it — so coming back to the
/// import screen later does not re-apply a photograph somebody has
/// already dealt with. The same bargain `PendingScan` makes above, for
/// the same reason.
final pendingStatementProvider =
    NotifierProvider<PendingStatement, StagedReceipt?>(PendingStatement.new);

class PendingStatement extends Notifier<StagedReceipt?> {
  @override
  StagedReceipt? build() => null;

  void park(StagedReceipt staged) => state = staged;

  StagedReceipt? take() {
    final held = state;
    state = null;
    return held;
  }
}
