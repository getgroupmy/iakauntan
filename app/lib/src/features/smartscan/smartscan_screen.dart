import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/skeletons.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/ocr_repository.dart';
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

  @override
  Widget build(BuildContext context) {
    final canWrite = ref.watch(canWriteProvider);
    // Never asked for while the setup chip is selected: `setup` is not
    // a value `scan_inbox` knows, and sending it would be a filter the
    // database quietly reads as `all`.
    final scans =
        _setup ? null : ref.watch(scanInboxProvider(_only));

    return Scaffold(
      appBar: AppBar(
        title: const Text('AI SmartScan'),
        actions: [
          if (canWrite)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: Space.md),
              child: FilledButton.icon(
                key: const ValueKey('smartscan-new'),
                onPressed: () async {
                  await runSmartScan(context, ref);
                  ref.invalidate(scanInboxProvider);
                },
                icon: const Icon(Icons.document_scanner_outlined, size: 18),
                label: const Text('Scan a document'),
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
                              'listed here with what it became.'
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
      key: ValueKey('scan-${entry.scanId}'),
      contentPadding: EdgeInsets.zero,
      leading: Icon(
        failed
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
