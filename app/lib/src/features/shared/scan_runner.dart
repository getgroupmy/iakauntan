import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../data/attachments_repository.dart';
import '../../data/ocr_repository.dart';
import 'mlkit_reader.dart';
import 'receipt_text.dart';

/// Reads one filed document, whichever reader the organization chose.
///
/// The two paths behind this are not variations on each other. Claude
/// and Document AI happen in an edge function: the charge is taken
/// before the provider is called and returned if it fails, and the app
/// only ever sees the answer. ML Kit happens here, on the phone, for
/// nothing — the file never leaves the device, and the log is written
/// afterwards rather than around it, because there is no money to
/// protect and nothing to refund.
///
/// Both callers go through this, so neither has to know which reader is
/// in force and the on-device path cannot quietly stop logging.
Future<OcrExtraction> readDocument(
  WidgetRef ref, {
  required OcrSettings ocr,
  required String attachmentId,
  required String storagePath,

  /// The file on this device, when there is one. A receipt just
  /// photographed has a path already, and fetching a copy of it back
  /// out of storage to read it would be silly.
  String? localPath,
}) async {
  final repo = ref.read(repoProvider)!;
  if (ocr.provider != 'mlkit') return repo.scanAttachment(attachmentId);

  if (!onDeviceReaderAvailable) {
    throw OcrException(
      'This organization reads documents on the device, which a browser '
      'cannot do. Use the app on a phone or tablet, or switch to a '
      'reader that runs on the server in Settings.',
    );
  }

  try {
    final text = localPath != null
        ? await readTextFromFile(localPath)
        : await readTextFromBytes(await repo.attachmentBytes(storagePath));

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
