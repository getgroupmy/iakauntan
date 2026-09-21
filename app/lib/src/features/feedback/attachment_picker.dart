
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../core/format.dart';
import '../../core/theme.dart';
import 'file_drop.dart';

/// What `0660` will take, said once so the screen and the database
/// cannot disagree about it.
///
/// Both numbers are enforced in SQL as well — five by
/// `attach_feedback_file`, ten megabytes by the bucket AND a CHECK on
/// the row. These exist so somebody is told BEFORE a twelve-megabyte
/// upload, not so the server can trust them.
const int maxFeedbackFiles = 5;
const int maxFeedbackFileBytes = 10 * 1024 * 1024;

/// Why a file was not taken, or null if it was.
///
/// A sentence rather than a bool, because "it was not added" with no
/// reason is the thing that makes somebody try the same file again.
String? feedbackFileRefusal(DroppedFile file, int alreadyChosen) {
  if (file.bytes.isEmpty) {
    return '${file.name} is empty.';
  }
  if (file.bytes.length > maxFeedbackFileBytes) {
    return '${file.name} is ${Fmt.bytes(file.bytes.length)}. '
        'The limit is ${Fmt.bytes(maxFeedbackFileBytes)}.';
  }
  if (alreadyChosen >= maxFeedbackFiles) {
    return 'That is more than $maxFeedbackFiles files. '
        'Remove one to add another.';
  }
  return null;
}

/// The files chosen for a report, with a way to choose more.
///
/// Holds them in memory and hands them up; nothing is uploaded until
/// the report is sent, because a file attached to a report that was
/// never filed is an object in a bucket with nothing pointing at it.
class AttachmentPicker extends StatelessWidget {
  const AttachmentPicker({
    super.key,
    required this.files,
    required this.onChanged,
    this.enabled = true,
  });

  final List<DroppedFile> files;
  final ValueChanged<List<DroppedFile>> onChanged;
  final bool enabled;

  /// Takes what it can and says what it could not, rather than
  /// refusing the whole drop because one file was too big. Somebody
  /// dragging four screenshots and a video wants the screenshots.
  static ({List<DroppedFile> kept, List<String> refused}) accept(
    List<DroppedFile> current,
    List<DroppedFile> incoming,
  ) {
    final kept = [...current];
    final refused = <String>[];
    for (final file in incoming) {
      final why = feedbackFileRefusal(file, kept.length);
      if (why != null) {
        refused.add(why);
      } else {
        kept.add(file);
      }
    }
    return (kept: kept, refused: refused);
  }

  Future<void> _pick(BuildContext context) async {
    // `withData: true` because the web has no paths and the upload
    // wants bytes everywhere anyway — reading them here means one code
    // path for a picked file and a dropped one.
    final result = await FilePicker.platform.pickFiles(
      allowMultiple: true,
      withData: true,
    );
    if (result == null) return;

    final incoming = <DroppedFile>[
      for (final f in result.files)
        if (f.bytes != null)
          DroppedFile(name: f.name, bytes: f.bytes!),
    ];
    final outcome = accept(files, incoming);
    onChanged(outcome.kept);
    if (outcome.refused.isNotEmpty && context.mounted) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(outcome.refused.first)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return FileDropTarget(
      enabled: enabled && files.length < maxFeedbackFiles,
      onFiles: (incoming) {
        final outcome = accept(files, incoming);
        onChanged(outcome.kept);
        if (outcome.refused.isNotEmpty) {
          ScaffoldMessenger.of(context)
            ..hideCurrentSnackBar()
            ..showSnackBar(SnackBar(content: Text(outcome.refused.first)));
        }
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              OutlinedButton.icon(
                key: const ValueKey('feedback-attach'),
                onPressed: enabled && files.length < maxFeedbackFiles
                    ? () => _pick(context)
                    : null,
                icon: const Icon(Icons.attach_file, size: 18),
                label: const Text('Attach'),
              ),
              const SizedBox(width: Space.sm),
              Expanded(
                child: Text(
                  // Only mention dropping where dropping works. On a
                  // phone this would be an instruction nobody can
                  // follow.
                  FileDropTarget.isSupported
                      ? 'A screenshot says more than a paragraph. '
                          'Drop files here too.'
                      : 'A screenshot says more than a paragraph.',
                  style: TextStyle(
                    fontSize: 12,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
          if (files.isNotEmpty) ...[
            const SizedBox(height: Space.sm),
            for (var i = 0; i < files.length; i++)
              _ChosenFile(
                file: files[i],
                onRemove: enabled
                    ? () => onChanged([...files]..removeAt(i))
                    : null,
              ),
          ],
        ],
      ),
    );
  }
}

class _ChosenFile extends StatelessWidget {
  const _ChosenFile({required this.file, this.onRemove});

  final DroppedFile file;
  final VoidCallback? onRemove;

  bool get _isImage =>
      (file.mimeType ?? '').startsWith('image/') ||
      RegExp(r'\.(png|jpe?g|gif|webp|bmp)$', caseSensitive: false)
          .hasMatch(file.name);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: [
          // The picture itself where there is one. A thumbnail is how
          // somebody notices they attached the wrong screenshot, which
          // a filename never tells them.
          if (_isImage)
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: Image.memory(
                file.bytes,
                width: 32,
                height: 32,
                fit: BoxFit.cover,
                // A file the browser called an image and the decoder
                // cannot read must not take the dialog down with it.
                errorBuilder: (_, __, ___) =>
                    Icon(Icons.broken_image_outlined,
                        size: 18, color: scheme.onSurfaceVariant),
              ),
            )
          else
            Icon(Icons.insert_drive_file_outlined,
                size: 18, color: scheme.onSurfaceVariant),
          const SizedBox(width: Space.sm),
          Expanded(
            child: Text(
              file.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12),
            ),
          ),
          Text(
            Fmt.bytes(file.size),
            style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
          ),
          IconButton(
            onPressed: onRemove,
            icon: const Icon(Icons.close, size: 16),
            tooltip: 'Remove',
            visualDensity: VisualDensity.compact,
          ),
        ],
      ),
    );
  }
}
