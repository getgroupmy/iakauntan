import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/skeletons.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/ocr_repository.dart';
import '../shared/file_drop.dart';
import '../shared/receipt_capture.dart';
import 'scan_destination.dart';
import 'scan_detail_sheet.dart';
import 'smartscan_settings.dart';
import 'scan_flow.dart';

/// AI SmartScan: the pile of paper, and what each sheet became.
///
/// Before this, scanning was four buttons on four screens and the
/// readings went nowhere anybody could look at them. A photograph that
/// quietly produced nothing was indistinguishable from one that posted
/// a bill — `ocr_scans` recorded what was read, what it cost and which
/// provider answered, and never recorded what the paper BECAME.
///
/// So this screen is the answer to "I scanned that receipt, where is
/// it?", which had no answer anywhere in the product. `0694` put the
/// link in the database; this is the list that reads it.
class SmartScanScreen extends ConsumerStatefulWidget {
  const SmartScanScreen({super.key});

  @override
  ConsumerState<SmartScanScreen> createState() => _SmartScanScreenState();
}

class _SmartScanScreenState extends ConsumerState<SmartScanScreen> {
  /// `all`, `posted` or `unposted`. The last is the one worth looking
  /// at: a photograph that became nothing is either work left half done
  /// or a reading that failed, and both want a person.
  ///
  /// `setup` is the fourth, and it is not a filter — it is the whole of
  /// how this company reads its paperwork, which used to live under
  /// Settings. A chip beside the filters rather than a second screen,
  /// because every refusal this module produces now names a control on
  /// the page the person is already standing on.
  String _only = 'all';

  bool get _setup => _only == 'setup';

  /// What stops the drop listener. Null off the web, where there is
  /// nothing listening. `0714`.
  void Function()? _stopDrop;

  /// True while a drop is being uploaded, so a second gesture over the
  /// same window does not start a second run over the first.
  bool _keeping = false;

  @override
  void initState() {
    super.initState();
    // On the DOCUMENT, not on a widget, because that is where the
    // browser fires it — and it has to be removed again when this
    // screen goes, or opening the screen twice would upload every
    // dropped file twice.
    _stopDrop = listenForDroppedFiles(_onDropped);
  }

  @override
  void dispose() {
    _stopDrop?.call();
    super.dispose();
  }

  Future<void> _onDropped(List<DroppedFile> files) async {
    if (!mounted || _keeping) return;
    if (!ref.read(canWriteProvider)) return;
    for (final f in files) {
      if (!mounted) return;
      await _keep(
        picked: CapturedFile(
          name: f.name,
          bytes: f.bytes,
          mimeType: f.mimeType,
        ),
      );
    }
  }

  /// Upload a document and keep it, without reading it. `0714`.
  Future<void> _keep({CapturedFile? picked}) async {
    if (_keeping) return;
    setState(() => _keeping = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final kept = await keepFileForLater(
        context,
        ref,
        table: ScanDestination.unknown.table,
        picked: picked,
      );
      if (kept == null) return;
      ref.invalidate(scanInboxProvider);
      messenger.showSnackBar(
        SnackBar(content: Text(keptFileMessage(kept))),
      );
    } catch (e) {
      // The one failure worth saying out loud: the file did not arrive,
      // so there is nothing to come back to.
      messenger.showSnackBar(
        SnackBar(content: Text('The file was not kept: $e')),
      );
    } finally {
      if (mounted) setState(() => _keeping = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final canWrite = ref.watch(canWriteProvider);
    // Enough room for two labelled buttons in one app bar, or not.
    final wide = MediaQuery.sizeOf(context).width >= 600;
    // Never asked for while the setup chip is selected: `setup` is not
    // a value `scan_inbox` knows, and sending it would be a filter the
    // database quietly reads as `all`.
    final scans =
        _setup ? null : ref.watch(scanInboxProvider(_only));

    return Scaffold(
      appBar: AppBar(
        title: const Text('AI SmartScan'),
        actions: [
          // Beside the scan and not instead of it. Two different jobs:
          // "read this now" costs a call to a model, and "keep this"
          // costs nothing and can wait until Tuesday.
          //
          // The label goes away on a narrow screen. Two labelled
          // buttons need more than a phone's app bar has -- they
          // overflowed it by 54 pixels, which Flutter draws as the
          // yellow-and-black bar and which means part of a control
          // cannot be reached. The icon keeps its tooltip, so what it
          // does is still sayable.
          if (canWrite)
            if (wide)
              OutlinedButton.icon(
                key: const ValueKey('smartscan-keep'),
                onPressed: _keeping ? null : () => _keep(),
                icon: const Icon(Icons.upload_file_outlined, size: 18),
                label: const Text('Upload'),
              )
            else
              IconButton(
                key: const ValueKey('smartscan-keep'),
                tooltip: 'Upload a file and keep it',
                onPressed: _keeping ? null : () => _keep(),
                icon: const Icon(Icons.upload_file_outlined),
              ),
          if (canWrite)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: Space.md),
              child: FilledButton.icon(
                key: const ValueKey('smartscan-new'),
                onPressed: _keeping
                    ? null
                    : () async {
                        await runSmartScan(context, ref);
                        ref.invalidate(scanInboxProvider);
                      },
                icon: const Icon(Icons.document_scanner_outlined, size: 18),
                label: Text(wide ? 'Scan a document' : 'Scan'),
              ),
            ),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              Space.lg,
              Space.md,
              Space.lg,
              0,
            ),
            child: Wrap(
              spacing: Space.sm,
              children: [
                for (final f in const [
                  (value: 'all', label: 'Everything'),
                  (value: 'unposted', label: 'Became nothing yet'),
                  (value: 'posted', label: 'Filed'),
                  (value: 'setup', label: 'How it reads'),
                ])
                  ChoiceChip(
                    key: ValueKey('smartscan-filter-${f.value}'),
                    label: Text(f.label),
                    selected: _only == f.value,
                    onSelected: (_) => setState(() => _only = f.value),
                  ),
              ],
            ),
          ),
          if (_setup)
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(Space.lg),
                child: SmartScanSettingsCard(
                  key: const ValueKey('smartscan-setup'),
                  canEdit: ref.watch(canAdminProvider),
                ),
              ),
            )
          else
            Expanded(
            child: AsyncView<List<ScanInboxEntry>>(
              value: scans!,
              onRetry: () => ref.invalidate(scanInboxProvider(_only)),
              skeleton: const ListSkeleton(rows: 6),
              builder: (rows) {
                if (rows.isEmpty) {
                  return EmptyState(
                    icon: Icons.document_scanner_outlined,
                    title: _only == 'all'
                        ? 'Nothing scanned yet'
                        : 'Nothing here',
                    message: _only == 'all'
                        ? 'Photograph a bill, a receipt, a letterhead or a '
                              'bank statement and it is read, filed and '
                              'listed here with what it became. Upload '
                              '${canDropFiles ? 'or drop in ' : ''}a file to '
                              'keep it here and read it later.'
                        : 'Try another filter.',
                  );
                }
                return ListView.separated(
                  padding: const EdgeInsets.all(Space.lg),
                  itemCount: rows.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (_, i) => _ScanRow(entry: rows[i]),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// One sheet: the file on the left, what it became on the right.
class _ScanRow extends ConsumerWidget {
  const _ScanRow({required this.entry});

  final ScanInboxEntry entry;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final failed = entry.status == 'failed' || entry.error != null;
    return ListTile(
      // The attachment where there is no scan. A key of `scan-null` on
      // every kept file would be the same key on all of them. `0714`.
      key: ValueKey(entry.scanId == null
          ? 'kept-${entry.attachmentId}'
          : 'scan-${entry.scanId}'),
      contentPadding: EdgeInsets.zero,
      leading: Icon(
        entry.isKeptOnly
            ? Icons.inventory_2_outlined
            : failed
            ? Icons.error_outline
            : entry.isPosted
            ? Icons.description_outlined
            : Icons.pending_outlined,
        color: failed ? context.colors.danger : null,
      ),
      title: Text(
        entry.fileName ?? 'A capture with no name',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(scanRowSubtitle(entry)),
      trailing: Text(
        Fmt.date(entry.scannedAt),
        style: Theme.of(context).textTheme.bodySmall,
      ),
      onTap: () => showScanDetail(context, entry),
    );
  }
}

/// The second line: what kind of paper it was taken to be, and what it
/// became.
///
/// Pure so it can be asserted. The sentence is the whole point of the
/// screen — "xxxx.jpg · Receipt · RC-123-11, 26 Sep 2026" — and the
/// three cases it has to tell apart all look alike from a distance: it
/// became something, it became nothing yet, and the reading failed.
String scanRowSubtitle(ScanInboxEntry entry) {
  final parts = <String>[];
  final kind = entry.kindLabel?.trim();
  if (kind != null && kind.isNotEmpty) parts.add(kind);

  // A file kept and never read. `0714`. First, because every branch
  // below it describes a READING — "not filed against anything yet" is
  // true of this too and says the wrong thing about it: it suggests a
  // reading happened and led nowhere.
  if (entry.isKeptOnly) {
    parts.add('Kept, not read yet');
    return parts.join(' · ');
  }

  if (entry.status == 'failed' || entry.error != null) {
    // The reason, not just the fact. A failed reading with no reason is
    // a row somebody can only shrug at.
    final why = entry.error?.trim();
    parts.add(why == null || why.isEmpty ? 'Could not be read' : why);
    return parts.join(' · ');
  }

  if (!entry.isPosted) {
    parts.add('Not filed against anything yet');
    return parts.join(' · ');
  }

  final label = entry.postedLabel?.trim();
  if (label == null || label.isEmpty) {
    // Posted, and the record has since been deleted. Said, because a
    // row that quietly read as unfiled would be a lie.
    parts.add('Filed against something that has since been deleted');
    return parts.join(' · ');
  }

  final on = entry.postedDate;
  parts.add(on == null ? label : '$label, ${Fmt.date(on)}');
  return parts.join(' · ');
}
