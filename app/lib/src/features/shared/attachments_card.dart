import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/attachments_repository.dart';

final attachmentsProvider = FutureProvider.autoDispose
    .family<List<Attachment>, ({String table, String id})>((ref, key) {
  return requireRepo(ref).attachments(key.table, key.id);
});

/// Files filed against one record — a receipt on a claim, an identity
/// document on a person, the instrument creating a charge.
///
/// Who may open them is decided by what they hang off, not by who
/// happens to be signed in: an accounts clerk reads a bill attachment
/// and not a passport scan, and an employee reads their own and nobody
/// else's. That is enforced in the database, on both the row and the
/// object, so it holds however the file is reached.
class AttachmentsCard extends ConsumerStatefulWidget {
  const AttachmentsCard({
    super.key,
    required this.table,
    required this.recordId,
    this.title = 'Attachments',
    this.subtitle,
  });

  final String table;
  final String recordId;
  final String title;
  final String? subtitle;

  @override
  ConsumerState<AttachmentsCard> createState() => _AttachmentsCardState();
}

class _AttachmentsCardState extends ConsumerState<AttachmentsCard> {
  bool _busy = false;

  ({String table, String id}) get _key =>
      (table: widget.table, id: widget.recordId);

  @override
  Widget build(BuildContext context) {
    final files = ref.watch(attachmentsProvider(_key));
    final canWrite = ref.watch(canWriteProvider);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Space.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SectionHeader(
              widget.title,
              subtitle: widget.subtitle,
              action: canWrite
                  ? Row(mainAxisSize: MainAxisSize.min, children: [
                      // Shown where there is plausibly a camera, which is
                      // the question `defaultTargetPlatform` actually
                      // answers: on the web it reports the browser's
                      // platform, so a phone browser says android or iOS
                      // and a laptop says macOS or Windows. That covers
                      // the app and the mobile web from one condition,
                      // and keeps a redundant button off a desktop where
                      // the capture attribute would silently degrade to
                      // an ordinary file dialog.
                      if (_cameraLikely)
                        IconButton(
                          tooltip: 'Photograph it',
                          onPressed: _busy ? null : _photograph,
                          icon: const Icon(Icons.photo_camera_outlined,
                              size: 20),
                        ),
                      OutlinedButton.icon(
                        onPressed: _busy ? null : _pick,
                        icon: _busy
                            ? const SizedBox(
                                height: 16,
                                width: 16,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2))
                            : const Icon(Icons.attach_file, size: 18),
                        label: const Text('Attach'),
                      ),
                    ])
                  : null,
            ),
            AsyncView(
              value: files,
              onRetry: () => ref.invalidate(attachmentsProvider(_key)),
              loading: const LinearProgressIndicator(),
              builder: (list) => list.isEmpty
                  ? Text(
                      'Nothing attached.',
                      style: Theme.of(context)
                          .textTheme
                          .bodySmall
                          ?.copyWith(color: context.scheme.onSurfaceVariant),
                    )
                  : Column(children: [
                      for (var i = 0; i < list.length; i++) ...[
                        if (i > 0) const Divider(height: 1),
                        _FileRow(
                          file: list[i],
                          canWrite: canWrite,
                          onChanged: () =>
                              ref.invalidate(attachmentsProvider(_key)),
                        ),
                      ],
                    ]),
            ),
          ],
        ),
      ),
    );
  }

  static bool get _cameraLikely =>
      defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS;

  Future<void> _pick() async {
    final file = await openFile();
    if (file == null || !mounted) return;
    await _upload(file.name, await file.readAsBytes(), file.mimeType);
  }

  /// Straight to the camera, not to a chooser.
  ///
  /// Somebody standing at a counter holding a receipt wants the shutter,
  /// not a menu offering them a photo library they have not put anything
  /// in yet. The library remains reachable through Attach, which on a
  /// phone offers it among everything else.
  Future<void> _photograph() async {
    final shot = await ImagePicker().pickImage(
      source: ImageSource.camera,
      // A receipt only has to be legible, and a full-resolution phone
      // photo is several megabytes of thermal paper. This keeps enough
      // detail to read the small print off the storage bill.
      imageQuality: 85,
      maxWidth: 2000,
    );
    if (shot == null || !mounted) return;

    // The camera names files things like `image_picker_XYZ.jpg`, which
    // tells nobody anything a year later.
    final stamp = DateTime.now();
    final name = 'receipt-${stamp.year}'
        '${stamp.month.toString().padLeft(2, '0')}'
        '${stamp.day.toString().padLeft(2, '0')}'
        '-${stamp.millisecondsSinceEpoch % 100000}.jpg';

    await _upload(name, await shot.readAsBytes(),
        shot.mimeType ?? 'image/jpeg');
  }

  Future<void> _upload(String name, Uint8List bytes, String? mimeType) async {
    if (!mounted) return;
    setState(() => _busy = true);
    await runWithFeedback(
      context,
      action: () => ref.read(repoProvider)!.uploadAttachment(
            table: widget.table,
            recordId: widget.recordId,
            fileName: name,
            bytes: bytes,
            mimeType: mimeType,
          ),
      successMessage: 'Attached',
    );
    if (mounted) setState(() => _busy = false);
    ref.invalidate(attachmentsProvider(_key));
  }
}

class _FileRow extends ConsumerWidget {
  const _FileRow({
    required this.file,
    required this.canWrite,
    required this.onChanged,
  });

  final Attachment file;
  final bool canWrite;
  final VoidCallback onChanged;

  IconData get _icon {
    final m = file.mimeType ?? '';
    if (m.startsWith('image/')) return Icons.image_outlined;
    if (m.contains('pdf')) return Icons.picture_as_pdf_outlined;
    if (m.contains('sheet') || m.contains('excel')) {
      return Icons.table_chart_outlined;
    }
    return Icons.description_outlined;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(_icon, size: 22, color: context.scheme.onSurfaceVariant),
      title: Text(file.fileName),
      subtitle: Text(
        [Fmt.dateTime(file.createdAt), file.sizeLabel]
            .where((s) => s.isNotEmpty)
            .join(' · '),
        style: const TextStyle(fontSize: 12),
      ),
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        IconButton(
          icon: const Icon(Icons.open_in_new, size: 18),
          tooltip: 'Open',
          onPressed: () => _open(context, ref),
        ),
        if (canWrite)
          IconButton(
            icon: const Icon(Icons.delete_outline, size: 18),
            tooltip: 'Remove',
            onPressed: () => _remove(context, ref),
          ),
      ]),
    );
  }

  Future<void> _open(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      // The bucket is private, so this is a link that expires rather
      // than a URL that keeps working after it has been forwarded.
      final url = await ref.read(repoProvider)!.attachmentUrl(file.storagePath);
      await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Could not open: $e')));
    }
  }

  Future<void> _remove(BuildContext context, WidgetRef ref) async {
    final ok = await confirm(
      context,
      title: 'Remove ${file.fileName}?',
      message: 'The file is deleted from storage as well as from the record.',
      confirmLabel: 'Remove',
    );
    if (!ok || !context.mounted) return;

    await runWithFeedback(
      context,
      action: () => ref.read(repoProvider)!.deleteAttachment(file),
      successMessage: 'Removed',
    );
    onChanged();
  }
}
