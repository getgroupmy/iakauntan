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
import 'scan_runner.dart';

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
  required bool camera,
  required String table,
}) async {
  final file = camera ? await photographReceipt() : await pickReceipt();
  if (file == null || !context.mounted) return null;

  final repo = ref.read(repoProvider)!;
  final placeholder = newUuid();
  final messenger = ScaffoldMessenger.of(context);

  String attachmentId;
  try {
    attachmentId = await repo.uploadAttachment(
      table: table,
      recordId: placeholder,
      fileName: file.name,
      bytes: file.bytes,
      mimeType: file.mimeType,
    );
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text('Could not attach it: $e')));
    return null;
  }

  try {
    final read = await readDocument(
      ref,
      ocr: ref.read(ocrStatusProvider).valueOrNull ?? OcrSettings.off,
      attachmentId: attachmentId,
      storagePath: '',
      // Already on this device, so the on-device reader reads it where
      // it is rather than fetching back the copy just uploaded.
      localPath: file.path,
    );
    ref.invalidate(ocrStatusProvider);
    return StagedReceipt(
      attachmentId: attachmentId,
      placeholderId: placeholder,
      read: read,
    );
  } catch (e) {
    ref.invalidate(ocrStatusProvider);
    messenger.showSnackBar(SnackBar(
      content: Text(e is OcrException
          ? '${e.message} The file is attached; type the figures in.'
          : 'Could not read it: $e'),
    ));
    return StagedReceipt(
      attachmentId: attachmentId,
      placeholderId: placeholder,
      read: null,
    );
  }
}

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
