import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
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
                  ? OutlinedButton.icon(
                      onPressed: _busy ? null : _pick,
                      icon: _busy
                          ? const SizedBox(
                              height: 16,
                              width: 16,
                              child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.attach_file, size: 18),
                      label: const Text('Attach'),
                    )
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

  Future<void> _pick() async {
    final file = await openFile();
    if (file == null || !mounted) return;

    setState(() => _busy = true);
    final bytes = await file.readAsBytes();
    if (!mounted) return;

    await runWithFeedback(
      context,
      action: () => ref.read(repoProvider)!.uploadAttachment(
            table: widget.table,
            recordId: widget.recordId,
            fileName: file.name,
            bytes: bytes,
            mimeType: file.mimeType,
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
