import 'dart:async';
import 'dart:js_interop';

import 'package:flutter/material.dart';
import 'package:web/web.dart' as web;

import 'file_drop_stub.dart' show DroppedFile;

export 'file_drop_stub.dart' show DroppedFile;

/// Dropping a file onto the window, on the web.
///
/// ---------------------------------------------------------------------
/// Why this listens on the DOCUMENT and not on a Flutter widget
///
/// Flutter web paints into a canvas. There is no DOM element under the
/// "drop here" rectangle to receive a `drop` event, and Flutter's own
/// pointer events carry no files — the browser gives a drop its
/// `DataTransfer` and nothing else does. So the listeners go on the
/// document, and the widget's job is only to say where to aim and to
/// light up while something is over the window.
///
/// The cost of that is honest and worth stating: while this widget is
/// mounted, a file dropped ANYWHERE on the page is taken as a drop on
/// this dialog. That is the right trade for a modal, which is the only
/// place it is used — nothing else on the screen wants a file at that
/// moment.
///
/// ---------------------------------------------------------------------
/// `preventDefault` on dragover is not optional
///
/// A browser's default action for a dropped file is to NAVIGATE TO IT.
/// Without the `dragover` handler calling `preventDefault`, dropping a
/// screenshot closes the app and opens the PNG, losing whatever was
/// typed. The `drop` handler prevents it too, because the two fire
/// independently and cancelling only one still leaves the window open
/// to it.
class FileDropTarget extends StatefulWidget {
  const FileDropTarget({
    super.key,
    required this.child,
    required this.onFiles,
    this.enabled = true,
  });

  final Widget child;
  final ValueChanged<List<DroppedFile>> onFiles;
  final bool enabled;

  static bool get isSupported => true;

  @override
  State<FileDropTarget> createState() => _FileDropTargetState();
}

class _FileDropTargetState extends State<FileDropTarget> {
  bool _over = false;

  // Held so they can be removed again. An anonymous closure passed to
  // `addEventListener` cannot be removed, and a dialog that is opened
  // and closed five times would leave five live listeners, each
  // delivering the same file to a dead widget.
  late final web.EventListener _onDragOver;
  late final web.EventListener _onDragLeave;
  late final web.EventListener _onDrop;

  @override
  void initState() {
    super.initState();
    _onDragOver = ((web.Event e) {
      e.preventDefault();
      if (widget.enabled && !_over && mounted) setState(() => _over = true);
    }).toJS;
    _onDragLeave = ((web.Event e) {
      e.preventDefault();
      if (_over && mounted) setState(() => _over = false);
    }).toJS;
    _onDrop = ((web.Event e) {
      e.preventDefault();
      if (mounted) setState(() => _over = false);
      if (!widget.enabled) return;
      unawaited(_take(e as web.DragEvent));
    }).toJS;

    web.document.addEventListener('dragover', _onDragOver);
    web.document.addEventListener('dragleave', _onDragLeave);
    web.document.addEventListener('drop', _onDrop);
  }

  @override
  void dispose() {
    web.document.removeEventListener('dragover', _onDragOver);
    web.document.removeEventListener('dragleave', _onDragLeave);
    web.document.removeEventListener('drop', _onDrop);
    super.dispose();
  }

  Future<void> _take(web.DragEvent event) async {
    final transfer = event.dataTransfer;
    if (transfer == null) return;
    final files = transfer.files;

    final picked = <DroppedFile>[];
    for (var i = 0; i < files.length; i++) {
      final file = files.item(i);
      if (file == null) continue;
      final buffer = await file.arrayBuffer().toDart;
      picked.add(DroppedFile(
        name: file.name,
        bytes: buffer.toDart.asUint8List(),
        // Empty for a type the browser does not recognise, which is
        // not the same as a file it refuses to read — so it becomes
        // null rather than an empty string that would be stored.
        mimeType: file.type.isEmpty ? null : file.type,
      ));
    }
    // One call for the whole drop, not one per file: the caller has a
    // limit to enforce, and enforcing it against a stream of single
    // files would accept the first few of a batch and reject the rest
    // without saying which.
    if (picked.isNotEmpty && mounted) widget.onFiles(picked);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 120),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        color: _over && widget.enabled
            ? scheme.primary.withValues(alpha: 0.08)
            : null,
        border: Border.all(
          color: _over && widget.enabled
              ? scheme.primary
              : Colors.transparent,
          width: 2,
        ),
      ),
      child: widget.child,
    );
  }
}
