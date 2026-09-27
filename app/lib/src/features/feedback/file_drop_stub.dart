import 'dart:typed_data';

import 'package:flutter/material.dart';

/// A file somebody chose, however they chose it.
///
/// Bytes rather than a path, because the web has no paths and the
/// upload wants bytes on every surface anyway.
class DroppedFile {
  const DroppedFile({
    required this.name,
    required this.bytes,
    this.mimeType,
  });

  final String name;
  final Uint8List bytes;
  final String? mimeType;

  int get size => bytes.length;
}

/// Dropping a file onto the window, where the window can be dropped on.
///
/// This is the half compiled for Android and iOS, where it draws its
/// child and nothing else. There is no drag-and-drop to support: a
/// phone has no pointer to drag with and no desktop to drag FROM, so
/// the Attach button is the whole story there.
///
/// It is not a stub in the sense of being unfinished. Doing nothing is
/// the correct behaviour on those two platforms, and the alternative —
/// a widget that draws a dashed "drop files here" rectangle at
/// somebody holding a phone — would be worse than absent.
class FileDropTarget extends StatelessWidget {
  const FileDropTarget({
    super.key,
    required this.child,
    required this.onFiles,
    this.enabled = true,
  });

  final Widget child;

  /// Never called here; the compile-time other half of the web one.
  final ValueChanged<List<DroppedFile>> onFiles;

  final bool enabled;

  /// Whether this build can be dropped onto, which the caller uses to
  /// decide whether to say so on the screen. False here.
  static bool get isSupported => false;

  @override
  Widget build(BuildContext context) => child;
}
