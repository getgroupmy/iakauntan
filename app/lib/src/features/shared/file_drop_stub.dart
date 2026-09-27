import 'dart:typed_data';

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

/// Listen for files dropped on the window.
///
/// Off the web there is nothing to listen to: a phone has no pointer
/// carrying a file and the desktop embedders do not deliver one. The
/// returned function is what stops listening, so a caller disposes it
/// the same way on every platform rather than branching.
///
/// [onFiles] is never called here. That is the point — the button is
/// still there, and the screen does not have to know which platform it
/// is drawing on.
void Function() listenForDroppedFiles(
  void Function(List<DroppedFile>) onFiles,
) {
  return () {};
}

/// Whether dropping a file onto this window is possible at all.
///
/// Read by the screen so it only promises what it can do: "or drop one
/// here" under a button on a phone would be an instruction nobody can
/// follow.
bool get canDropFiles => false;
