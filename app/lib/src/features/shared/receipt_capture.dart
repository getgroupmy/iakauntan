import 'dart:math';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart' show defaultTargetPlatform, kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/providers.dart';
import '../../data/attachments_repository.dart';
import '../../data/ocr_repository.dart';
import '../smartscan/scan_availability.dart';
import '../smartscan/scan_blocked_dialog.dart';
import 'doc_scanner.dart';
import 'scan_progress.dart';
import 'scan_runner.dart';
import 'text_reader.dart';

/// Whether there is plausibly a camera, which is the question
/// `defaultTargetPlatform` actually answers: on the web it reports the
/// browser's platform, so a phone browser says android or iOS and a
/// laptop says macOS or Windows. That covers the app and the mobile web
/// from one condition, and keeps a redundant button off a desktop where
/// the capture attribute would silently degrade to a file dialog.
bool get cameraLikely =>
    defaultTargetPlatform == TargetPlatform.android ||
    defaultTargetPlatform == TargetPlatform.iOS;

/// One file, from the shutter or from disk.
class CapturedFile {
  const CapturedFile({
    required this.name,
    required this.bytes,
    required this.mimeType,
    this.path,
  });

  final String name;
  final Uint8List bytes;
  final String? mimeType;

  /// Where the file sits on this device, when it sits anywhere. Null on
  /// the web, where a picked file is a blob and not a path. The
  /// on-device reader wants this: reading the file that is already here
  /// beats uploading it and fetching a copy back.
  final String? path;
}

/// Straight to the camera, not to a chooser.
///
/// Somebody standing at a counter holding a receipt wants the shutter,
/// not a menu offering them a photo library they have not put anything
/// in yet.
Future<CapturedFile?> photographReceipt() async {
  final shot = await ImagePicker().pickImage(
    source: ImageSource.camera,
    // A receipt only has to be legible, and a full-resolution phone
    // photo is several megabytes of thermal paper. This keeps enough
    // detail to read the small print off the storage bill, and keeps
    // the file under what the reader will accept.
    imageQuality: 85,
    maxWidth: 2000,
  );
  if (shot == null) return null;

  // The camera names files things like `image_picker_XYZ.jpg`, which
  // tells nobody anything a year later.
  final stamp = DateTime.now();
  final name = 'receipt-${stamp.year}'
      '${stamp.month.toString().padLeft(2, '0')}'
      '${stamp.day.toString().padLeft(2, '0')}'
      '-${stamp.millisecondsSinceEpoch % 100000}.jpg';

  return CapturedFile(
    name: name,
    bytes: await shot.readAsBytes(),
    mimeType: shot.mimeType ?? 'image/jpeg',
    path: kIsWeb ? null : shot.path,
  );
}

/// The scanner, which is the better shutter where there is one.
///
/// Edge detection, perspective correction and glare removal before
/// anything is read. It sits upstream of the reader rather than beside
/// it: a deskewed, cropped receipt reads better whichever reader is in
/// force, and better still when nobody reads it at all and the file is
/// just the evidence on a claim.
///
/// Falls back to the plain camera where the scanner is not there —
/// on Android it is delivered through Play services, so a Huawei or a
/// de-Googled build has the camera and not this. That is a fallback and
/// not an error, and it happens without saying anything, because
/// somebody holding a receipt does not need to be told which of two
/// camera implementations opened.
Future<CapturedFile?> scanReceipt() async {
  if (!docScannerLikely) return photographReceipt();

  final ScannedPage? page;
  try {
    page = await scanDocumentPage();
  } catch (e) {
    if (isScannerUnavailable(e)) return photographReceipt();
    rethrow;
  }
  if (page == null) return null;

  final stamp = DateTime.now();
  final name = 'scan-${stamp.year}'
      '${stamp.month.toString().padLeft(2, '0')}'
      '${stamp.day.toString().padLeft(2, '0')}'
      '-${stamp.millisecondsSinceEpoch % 100000}.jpg';

  return CapturedFile(
    name: name,
    bytes: page.bytes,
    mimeType: 'image/jpeg',
    path: page.path,
  );
}

Future<CapturedFile?> pickReceipt() async {
  final file = await openFile();
  if (file == null) return null;
  return CapturedFile(
    name: file.name,
    bytes: await file.readAsBytes(),
    mimeType: file.mimeType,
    path: kIsWeb ? null : file.path,
  );
}

/// Where a capture comes from.
enum CaptureSource { scanner, camera, file }

/// A receipt filed and read before the record it belongs to exists.
///
/// Which is the ordinary case: somebody photographs the receipt and
/// *then* decides what it was. The file is parked against a placeholder
/// id and moved onto the expense once the expense has one — see
/// [RepoOcr.refileAttachment], which moves the object as well as the
/// row, because the storage policies read the record out of the object
/// name.
class StagedReceipt {
  const StagedReceipt({
    required this.attachmentId,
    required this.placeholderId,
    required this.read,
  });

  final String attachmentId;
  final String placeholderId;

  /// Null when the capture was filed but the reading failed or was
  /// declined — the paper is still worth keeping.
  final OcrExtraction? read;
}

/// Captures a receipt, files it, and reads it.
///
/// Returns null when the capture was cancelled. A failure *after* the
/// upload still returns a [StagedReceipt] with no reading, because by
/// then there is a file worth attaching whatever the reader made of it.
Future<StagedReceipt?> captureAndRead(
  BuildContext context,
  WidgetRef ref, {
  required CaptureSource source,
  required String table,

  /// A file already in hand, instead of asking for one.
  ///
  /// The bank statement importer picks the file ITSELF, because it has
  /// to look at the bytes before it knows whether this is a reader's
  /// job at all: a CSV is parsed here for nothing and must never reach
  /// a scan. Asking again would be a second file dialog over a file
  /// somebody has already chosen.
  ///
  /// Everything after the pick is the same, and deliberately so -- the
  /// PDF refusal that happens before the upload, the progress modal,
  /// the attachment that is kept when the reading fails.
  CapturedFile? picked,
}) async {
  final file = picked ??
      switch (source) {
        CaptureSource.scanner => await scanReceipt(),
        CaptureSource.camera => await photographReceipt(),
        CaptureSource.file => await pickReceipt(),
      };
  if (file == null || !context.mounted) return null;

  // Before the upload, not after it. `2f012feb` moved the "scanning is
  // switched off" refusal ahead of the camera; this is the same
  // argument one step further in, for the refusal that needs the FILE
  // to be answerable.
  //
  // A PDF handed to a chat-completions reader is refused by name in
  // `supabase/functions/ocr/index.ts` — correctly — but that refusal
  // arrives after an upload, after a charge and after the refund of
  // it. Everything it turns on is known here: `reads_pdf` comes off
  // `ocr_status` (`0697`) and the first four bytes of the file are in
  // hand.
  //
  // Awaited rather than read off the cache, for the reason the read
  // below is: nothing watches this provider on some of the screens
  // that reach here, and `valueOrNull` would come back null — which
  // this function reads as "nobody has said", and would let the PDF
  // through to the refusal it exists to predict.
  //
  // And caught, because this await now happens BEFORE the upload. A
  // status call that will not answer used to surface as "could not
  // read it" over a file that had been kept; throwing here would lose
  // the capture entirely over a question that is only ever an
  // optimisation. Null is exactly what `pdfBlock` treats as "nobody
  // has said", so it lets the scan go on to the edge function, which
  // is the real gate.
  OcrSettings? known;
  try {
    known = await ref.read(ocrStatusProvider.future);
  } catch (_) {
    known = null;
  }
  if (!context.mounted) return null;
  final block = pdfBlock(
    known,
    isPdf: looksLikePdf(file.mimeType, file.bytes),
    canAdmin: ref.read(canAdminProvider),
    deviceReadsPdf: onDeviceReadsPdf,
  );
  if (block != null) {
    await showScanBlocked(context, block);
    return null;
  }

  final repo = ref.read(repoProvider)!;
  final placeholder = newUuid();
  final messenger = ScaffoldMessenger.of(context);

  // Both halves inside one modal. Asked for as "once a document is
  // uploaded for scanning it should have a progress popup and block all
  // activity till its 100% completed".
  //
  // Between the two there was NOTHING on screen. The upload and the
  // read are one press and a wait of several seconds — longer when the
  // chosen reader is having a bad afternoon and `0703`'s fallback gets
  // a turn — and the whole of it looked like a button that had not
  // worked. Which invites the second press, and the second press is a
  // second upload and a second charge.
  //
  // Nothing is SAID from inside the modal. A snackbar raised under a
  // barrier is a sentence nobody reads, so the outcome comes back as a
  // value and every message happens below, once the dialog has gone.
  final outcome = await whileScanning<_Capture>(
    context,
    action: (report) async {
      final String attachmentId;
      try {
        attachmentId = await repo.uploadAttachment(
          table: table,
          recordId: placeholder,
          fileName: file.name,
          bytes: file.bytes,
          mimeType: file.mimeType,
        );
      } catch (e) {
        return (attachmentId: null, read: null, error: e);
      }

      report(ScanStage.reading);
      try {
        // Awaited, not read off the cache. On the expenses screen
        // something watches this provider so it is warm; on the
        // document list nothing does, and `valueOrNull` came back null
        // there — which read as "not on the device" and sent a browser
        // scan to the server, where the server correctly refused it.
        final read = await readDocument(
          ref,
          // The same answer the PDF question above was asked of, rather
          // than a second round trip that could disagree with it. Asked
          // again only where that one did not come back, and inside
          // this try, where a refusal reaches the snackbar over a file
          // that is already attached.
          ocr: known ?? await ref.read(ocrStatusProvider.future),
          attachmentId: attachmentId,
          mimeType: file.mimeType,
          // Already on this device, so the on-device reader reads what
          // is here rather than fetching back the copy just uploaded. A
          // phone capture has a path; a browser capture has only bytes,
          // and passing both means neither platform falls back to
          // storage.
          localPath: file.path,
          localBytes: file.bytes,
          onLocalFallback: () => report(ScanStage.readingHere),
        );
        return (attachmentId: attachmentId, read: read, error: null);
      } catch (e) {
        return (attachmentId: attachmentId, read: null, error: e);
      }
    },
  );

  final attachmentId = outcome.attachmentId;
  if (attachmentId == null) {
    messenger.showSnackBar(
        SnackBar(content: Text('Could not attach it: ${outcome.error}')));
    return null;
  }

  // A scan row exists and the balance may have moved whichever way the
  // reading went, so what is drawn off those has to be asked again. Not
  // on the upload failure above, where nothing was read and nothing was
  // spent.
  ref.invalidate(ocrStatusProvider);

  final failure = outcome.error;
  if (failure != null) {
    messenger.showSnackBar(SnackBar(
      content: Text(failure is OcrException
          ? '${failure.message} The file is attached; type the figures in.'
          : 'Could not read it: $failure'),
    ));
  }
  return StagedReceipt(
    attachmentId: attachmentId,
    placeholderId: placeholder,
    read: outcome.read,
  );
}

/// What one capture came to, carried out of the modal rather than acted
/// on inside it.
///
/// A null [attachmentId] is an upload that failed, which is the one
/// outcome with no file to keep. An error WITH an id is a file that is
/// attached and was not read — still handed back, because the paper is
/// worth keeping whatever the reader made of it.
typedef _Capture = ({
  String? attachmentId,
  OcrExtraction? read,
  Object? error,
});

/// A version 4 UUID, for parking an attachment against a record that
/// does not exist yet. `entity_id` is a uuid column, so this cannot be
/// any old unique string.
String newUuid() {
  final r = Random.secure();
  final b = List<int>.generate(16, (_) => r.nextInt(256));
  b[6] = (b[6] & 0x0f) | 0x40; // version 4
  b[8] = (b[8] & 0x3f) | 0x80; // variant 1
  String hex(int from, int to) => b
      .sublist(from, to)
      .map((v) => v.toRadixString(16).padLeft(2, '0'))
      .join();
  return '${hex(0, 4)}-${hex(4, 6)}-${hex(6, 8)}-${hex(8, 10)}-${hex(10, 16)}';
}
