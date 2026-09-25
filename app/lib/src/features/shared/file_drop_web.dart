/// Dropping a file onto the tab.
///
/// The browser fires `dragover` and `drop` on the document whether or
/// not anybody is listening, and its DEFAULT for a dropped PDF is to
/// navigate away and display it — which on a single-page app throws
/// away whatever the person was in the middle of. So `preventDefault`
/// on both is not a nicety here; without it the feature is worse than
/// absent.
library;

import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

/// A file the browser handed over.
class DroppedFile {
  const DroppedFile({
    required this.name,
    required this.bytes,
    this.mimeType,
  });

  final String name;
  final Uint8List bytes;
  final String? mimeType;
}

/// Listen for files dropped on the window; returns the stop function.
///
/// Both listeners are added and both are removed, because this outlives
/// the widget that started it otherwise: a screen opened, left and
/// opened again would stack a second listener on the document and
/// upload every dropped file twice.
///
/// Directories and dragged text are ignored rather than refused. A
/// `DataTransferItem` whose `getAsFile()` is null is a folder or a
/// selection, and there is nothing to upload.
void Function() listenForDroppedFiles(
  void Function(List<DroppedFile>) onFiles,
) {
  void over(web.Event e) => e.preventDefault();

  void dropped(web.Event e) {
    e.preventDefault();
    final transfer = (e as web.DragEvent).dataTransfer;
    if (transfer == null) return;
    final files = transfer.files;
    final out = <web.File>[];
    for (var i = 0; i < files.length; i++) {
      final f = files.item(i);
      if (f != null) out.add(f);
    }
    if (out.isEmpty) return;
    unawaited(_read(out, onFiles));
  }

  final overJs = over.toJS;
  final dropJs = dropped.toJS;
  web.document.addEventListener('dragover', overJs);
  web.document.addEventListener('drop', dropJs);
  return () {
    web.document.removeEventListener('dragover', overJs);
    web.document.removeEventListener('drop', dropJs);
  };
}

/// Read every dropped file's bytes, then hand them over in one call.
///
/// One call rather than one per file, so a caller that uploads them can
/// say "four files kept" instead of raising four separate messages over
/// one gesture.
Future<void> _read(
  List<web.File> files,
  void Function(List<DroppedFile>) onFiles,
) async {
  final out = <DroppedFile>[];
  for (final f in files) {
    try {
      final buffer = await f.arrayBuffer().toDart;
      out.add(DroppedFile(
        name: f.name,
        bytes: buffer.toDart.asUint8List(),
        // Empty rather than absent is what a browser gives for a type it
        // does not recognise, and an empty string travels into a
        // `mime_type` column as a value that is not a MIME type.
        mimeType: f.type.isEmpty ? null : f.type,
      ));
    } catch (_) {
      // One unreadable file must not lose the other three.
    }
  }
  if (out.isNotEmpty) onFiles(out);
}

bool get canDropFiles => true;
