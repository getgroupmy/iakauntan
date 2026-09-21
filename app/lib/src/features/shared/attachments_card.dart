import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/skeletons.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/attachments_repository.dart';
import '../../data/ocr_repository.dart';
import 'text_reader.dart';
import 'doc_scanner.dart';
import 'receipt_capture.dart';
import 'scan_runner.dart';
import 'scan_result_dialog.dart';

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
    this.onExtracted,
    this.canAttach,
  });

  final String table;
  final String recordId;
  final String title;
  final String? subtitle;

  /// Who may file something here, when it is not the usual answer.
  ///
  /// The usual answer is `can_write` on the organization, which is right
  /// for a bill and wrong for an expense claim: the person holding the
  /// receipt is the claimant, and a claimant is not staff. The database
  /// says the same — see `app.can_attach_to` — and this is the screen
  /// agreeing with it rather than hiding a button the database would
  /// have allowed.
  final bool? canAttach;

  /// Where a scanned document's fields should go.
  ///
  /// Given a callback, Scan hands the extraction straight to the form
  /// behind this card. Without one it shows what was read, which is
  /// still worth having on a record that is finished and read-only —
  /// somebody checking a posted bill against its paper.
  final void Function(OcrExtraction)? onExtracted;

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
    // Typed, not inferred. `ProviderListenable` is covariant, so `??`
    // makes the context type `bool?` and `ref.watch` obligingly returns
    // one — leaving `canWrite` nullable for no reason anybody reading
    // this would guess.
    final bool canWrite = widget.canAttach ?? ref.watch(canWriteProvider);

    // 0323. Attachments are a module. `app.can_attach_to` refuses every
    // write without it — the row, the file, and deleting either — so a
    // shutter button that stayed would be a button that fails.
    //
    // Reading is deliberately not gated, in the database and here: the
    // list below still draws whatever was filed before. A company that
    // does not take the module cannot add another document; it does not
    // lose the ones it has, and neither does the auditor asking for
    // them.
    final module = moduleEnabled(ref, 'attachments');
    final canAdd = canWrite && module;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Space.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SectionHeader(
              widget.title,
              subtitle: widget.subtitle,
              action: canAdd
                  ? Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // The scanner where there is one, then the plain
                        // shutter. Both, rather than one replacing the
                        // other: the scanner insists on finding a document
                        // in the frame, and somebody photographing a
                        // damaged label or a whiteboard needs the camera.
                        if (docScannerLikely)
                          IconButton(
                            tooltip: 'Scan a document',
                            onPressed: _busy ? null : _scanDocument,
                            icon: const Icon(
                              Icons.document_scanner_outlined,
                              size: 20,
                            ),
                          ),
                        if (cameraLikely)
                          IconButton(
                            tooltip: 'Photograph it',
                            onPressed: _busy ? null : _photograph,
                            icon: const Icon(
                              Icons.photo_camera_outlined,
                              size: 20,
                            ),
                          ),
                        OutlinedButton.icon(
                          onPressed: _busy ? null : _pick,
                          icon: _busy
                              ? const SizedBox(
                                  height: 16,
                                  width: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.attach_file, size: 18),
                          label: const Text('Attach'),
                        ),
                      ],
                    )
                  : null,
            ),
            AsyncView(
              value: files,
              onRetry: () => ref.invalidate(attachmentsProvider(_key)),
              // Two, because most records carry one or two files and an
              // outline longer than the answer reads as attachments
              // that disappeared.
              skeleton: const ListSkeleton(rows: 2),
              builder: (list) => list.isEmpty
                  ? Text(
                      'Nothing attached.',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: context.scheme.onSurfaceVariant,
                      ),
                    )
                  : Column(
                      children: [
                        for (var i = 0; i < list.length; i++) ...[
                          if (i > 0) const Divider(height: 1),
                          _FileRow(
                            file: list[i],
                            canWrite: canAdd,
                            onChanged: () =>
                                ref.invalidate(attachmentsProvider(_key)),
                            onExtracted: widget.onExtracted,
                          ),
                        ],
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }

  /// The library stays reachable through Attach, which on a phone offers
  /// it among everything else.
  Future<void> _pick() async => _upload(await pickReceipt());

  Future<void> _photograph() async => _upload(await photographReceipt());

  Future<void> _scanDocument() async => _upload(await scanReceipt());

  Future<void> _upload(CapturedFile? file) async {
    if (file == null || !mounted) return;
    setState(() => _busy = true);
    await runWithFeedback(
      context,
      action: () => ref
          .read(repoProvider)!
          .uploadAttachment(
            table: widget.table,
            recordId: widget.recordId,
            fileName: file.name,
            bytes: file.bytes,
            mimeType: file.mimeType,
          ),
      successMessage: 'Attached',
    );
    if (mounted) setState(() => _busy = false);
    ref.invalidate(attachmentsProvider(_key));
  }
}

class _FileRow extends ConsumerStatefulWidget {
  const _FileRow({
    required this.file,
    required this.canWrite,
    required this.onChanged,
    this.onExtracted,
  });

  final Attachment file;
  final bool canWrite;
  final VoidCallback onChanged;
  final void Function(OcrExtraction)? onExtracted;

  @override
  ConsumerState<_FileRow> createState() => _FileRowState();
}

class _FileRowState extends ConsumerState<_FileRow> {
  bool _scanning = false;

  Attachment get file => widget.file;

  /// There is nothing to read in a spreadsheet or a zip.
  bool get _readable {
    final m = file.mimeType ?? '';
    return m.startsWith('image/') || m.contains('pdf');
  }

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
  Widget build(BuildContext context) {
    // Off for most organizations, and there is no row until somebody
    // turns it on, so the absent case has to read as off rather than as
    // a spinner that never resolves.
    final ocr = ref.watch(ocrStatusProvider).valueOrNull ?? OcrSettings.off;

    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(_icon, size: 22, color: context.scheme.onSurfaceVariant),
      title: Text(file.fileName),
      subtitle: Text(
        [
          Fmt.dateTime(file.createdAt),
          file.sizeLabel,
        ].where((s) => s.isNotEmpty).join(' · '),
        style: const TextStyle(fontSize: 12),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Not offered where the chosen reader cannot run: an
          // organization on the on-device reader has no scan button in a
          // browser, because pressing it could only ever explain itself.
          if (ocr.enabled && _readable && widget.canWrite && _readerHere(ocr))
            IconButton(
              icon: _scanning
                  ? const SizedBox(
                      height: 16,
                      width: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.document_scanner_outlined, size: 18),
              // Says what it costs before it is pressed, because it is
              // the one button on this screen that spends money.
              tooltip: ocr.keySource == 'platform' && ocr.price > 0
                  ? 'Read this document (${Fmt.money(ocr.price)})'
                  : 'Read this document',
              onPressed: _scanning ? null : _scan,
            ),
          IconButton(
            icon: const Icon(Icons.open_in_new, size: 18),
            tooltip: 'Open',
            onPressed: _open,
          ),
          if (widget.canWrite)
            IconButton(
              icon: const Icon(Icons.delete_outline, size: 18),
              tooltip: 'Remove',
              onPressed: _remove,
            ),
        ],
      ),
    );
  }

  /// Whether the reader this organization chose exists on this device.
  bool _readerHere(OcrSettings ocr) => !ocr.onDevice || onDeviceReaderAvailable;

  Future<void> _scan() async {
    setState(() => _scanning = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final read = await readDocument(
        ref,
        // Awaited rather than read off the cache, for the same reason
        // the capture path is: a cold provider reads as "not on the
        // device" and sends the scan somewhere it was never meant to go.
        ocr: await ref.read(ocrStatusProvider.future),
        attachmentId: file.id,
        storagePath: file.storagePath,
        mimeType: file.mimeType,
      );
      if (!mounted) return;
      // The balance moved, so what the next tooltip says about it should
      // be true.
      ref.invalidate(ocrStatusProvider);

      final apply = widget.onExtracted;
      if (apply == null) {
        await showScanResult(context, read);
      } else {
        // What comes back is what the person on the screen settled on,
        // which is not always what the reader said.
        final accepted = await showScanResult(context, read, canApply: true);
        if (accepted != null) {
          await rememberDocumentKind(ref,
              attachmentId: file.id, accepted: accepted);
          apply(accepted);
        }
      }
    } catch (e) {
      // The database's own refusals — scanning switched off, no credit,
      // a provider that would not read it — arrive already written for
      // somebody to read, so they are shown rather than summarised.
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            e is OcrException ? e.message : 'Could not read it: $e',
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }

  Future<void> _open() async {
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

  Future<void> _remove() async {
    final ok = await confirm(
      context,
      title: 'Remove ${file.fileName}?',
      message: 'The file is deleted from storage as well as from the record.',
      confirmLabel: 'Remove',
    );
    if (!ok || !mounted) return;

    await runWithFeedback(
      context,
      action: () => ref.read(repoProvider)!.deleteAttachment(file),
      successMessage: 'Removed',
    );
    widget.onChanged();
  }
}
