/// Saving a file, and writing down that it left the building.
///
/// The download helpers in `download.dart` do the saving; these two wrap
/// them so an auditor can answer "who took a copy of the payroll", which
/// no amount of change history can. Every screen that hands a file to
/// somebody goes through here rather than calling `saveTextFile` or
/// `saveBytesFile` directly.
///
/// Recorded whether or not the save succeeded, and that is deliberate.
/// `saveBytesFile` returns false on Android and iOS, where the caller
/// falls back to the clipboard -- and a copy on the clipboard is a copy
/// that left the building. What is recorded is that the export was
/// produced, which is the fact worth having.
///
/// A failure to record never breaks the download. The person asked for
/// their file; refusing to hand it over because the log was unreachable
/// would be a strange way to keep books.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/repository.dart';
import 'download.dart';
import 'providers.dart';

Future<bool> exportTextFile(
  WidgetRef? ref,
  String filename,
  String mimeType,
  String text, {
  required String what,
  String? detail,
}) async {
  final saved = await saveTextFile(filename, mimeType, text);
  await _note(ref, what, detail ?? filename);
  return saved;
}

Future<bool> exportBytesFile(
  WidgetRef? ref,
  String filename,
  String mimeType,
  Uint8List bytes, {
  required String what,
  String? detail,
}) async {
  final saved = await saveBytesFile(filename, mimeType, bytes);
  await _note(ref, what, detail ?? filename);
  return saved;
}

Future<void> _note(WidgetRef? ref, String what, String? detail) async {
  if (ref == null) return;
  final repo = ref.read(repoProvider);
  if (repo == null) return;
  try {
    await repo.recordExport(what, detail);
  } catch (e) {
    debugPrint('export not recorded: $e');
  }
}
