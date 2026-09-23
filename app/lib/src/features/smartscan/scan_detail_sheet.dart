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
import '../../data/scan_kinds_repository.dart';
import 'scan_destination.dart';
import 'scan_field_map.dart';

/// Everything one photograph produced.
///
/// The result dialog shows a reading while somebody is deciding whether
/// to accept it. This shows it afterwards, next to the columns it
/// filled and the record it became — which is the question the result
/// dialog cannot answer because at that moment there is no record yet.
Future<void> showScanDetail(BuildContext context, ScanInboxEntry entry) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _ScanDetailSheet(entry: entry),
    );

class _ScanDetailSheet extends ConsumerWidget {
  const _ScanDetailSheet({required this.entry});

  final ScanInboxEntry entry;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final reading = ref.watch(scanReadingProvider(entry.scanId));
    final kinds = ref.watch(offeredScanKindsProvider).valueOrNull ?? const [];

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.75,
      maxChildSize: 0.95,
      builder: (_, controller) => ListView(
        controller: controller,
        padding: const EdgeInsets.fromLTRB(Space.lg, 0, Space.lg, Space.xl),
        children: [
          Text(
            entry.fileName ?? 'A capture with no name',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: Space.xs),
          Text(
            'Read ${Fmt.dateTime(entry.scannedAt)}'
            '${entry.provider == null ? '' : ' by ${entry.provider}'}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: Space.md),

          _WhatItBecame(entry: entry),

          if (entry.hasImage) ...[
            const SizedBox(height: Space.md),
            OutlinedButton.icon(
              key: const ValueKey('scan-view-image'),
              onPressed: () => _openImage(context, ref),
              icon: const Icon(Icons.image_outlined, size: 18),
              label: const Text('View the image'),
            ),
          ],

          const SizedBox(height: Space.lg),
          AsyncView<OcrExtraction?>(
            value: reading,
            onRetry: () => ref.invalidate(scanReadingProvider(entry.scanId)),
            // Rows of a label over its column, with a value on the
            // right — which is a shape that IS decided before the
            // payload arrives, even though how many of them there are
            // is not. The headline above this says what the scan
            // became and is drawn already, so what is outstanding here
            // really is just the values.
            skeleton: const ListSkeleton(rows: 5, leading: false),
            builder: (read) {
              if (read == null) {
                return Text(
                  entry.error?.trim().isNotEmpty == true
                      ? 'Nothing was read. ${entry.error}'
                      : 'Nothing was read off this one.',
                  style: Theme.of(context).textTheme.bodyMedium,
                );
              }
              final to = destinationFor(read, kinds);
              final mapped = readingColumns(read, to);
              final asked = readerColumns(read, to);
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (mapped.isNotEmpty) ...[
                    _Heading('What it filled in', to: to),
                    for (final f in mapped) _FieldRow(field: f),
                  ],
                  if (asked.isNotEmpty) ...[
                    const SizedBox(height: Space.lg),
                    _Heading('What the reader was asked for', to: to),
                    for (final f in asked) _FieldRow(field: f),
                  ],
                  if (read.lines.isNotEmpty) ...[
                    const SizedBox(height: Space.lg),
                    Text(
                      '${read.lines.length} line'
                      '${read.lines.length == 1 ? '' : 's'}',
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    for (final l in read.lines)
                      ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        title: Text(l.description ?? '—'),
                        trailing: Text(
                          l.amount == null ? '' : Fmt.money(l.amount!),
                        ),
                      ),
                  ],
                  if (read.rows.isNotEmpty) ...[
                    const SizedBox(height: Space.lg),
                    Text(
                      '${read.rows.length} statement line'
                      '${read.rows.length == 1 ? '' : 's'}',
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                  ],
                  if (mapped.isEmpty && asked.isEmpty && read.lines.isEmpty)
                    Text(
                      'It was read, and nothing on it mapped to a column.',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  Future<void> _openImage(BuildContext context, WidgetRef ref) async {
    final repo = ref.read(repoProvider);
    final path = entry.storagePath;
    if (repo == null || path == null) return;
    try {
      // The bucket is private, so this is a link that expires rather
      // than a URL that keeps working after it has been forwarded.
      final url = await repo.attachmentUrl(path);
      await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Could not open it: $e')));
      }
    }
  }
}

/// The headline answer, and the whole reason the screen exists.
class _WhatItBecame extends StatelessWidget {
  const _WhatItBecame({required this.entry});

  final ScanInboxEntry entry;

  @override
  Widget build(BuildContext context) {
    final failed = entry.status == 'failed' || entry.error != null;
    final label = entry.postedLabel?.trim();
    final (icon, text) = failed
        ? (Icons.error_outline, 'It could not be read.')
        : !entry.isPosted
        ? (
            Icons.pending_outlined,
            'Nothing has been created from this yet.',
          )
        : label == null || label.isEmpty
        ? (
            Icons.link_off,
            'It was filed against a record that has since been deleted.',
          )
        : (
            Icons.description_outlined,
            entry.postedDate == null
                ? 'It became $label.'
                : 'It became $label, ${Fmt.date(entry.postedDate!)}.',
          );

    return Card(
      margin: EdgeInsets.zero,
      child: ListTile(
        leading: Icon(icon, color: failed ? context.colors.danger : null),
        title: Text(text),
        subtitle: entry.kindLabel == null
            ? null
            : Text('Taken to be a ${entry.kindLabel!.toLowerCase()}'),
      ),
    );
  }
}

class _Heading extends StatelessWidget {
  const _Heading(this.text, {required this.to});

  final String text;
  final ScanDestination to;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: Space.sm),
        child: Text(
          '$text — ${to.label.toLowerCase()}',
          style: Theme.of(context).textTheme.titleSmall,
        ),
      );
}

/// A value, and the column it lands in.
class _FieldRow extends StatelessWidget {
  const _FieldRow({required this.field});

  final ReadField field;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Space.xs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            flex: 2,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(field.label, style: theme.textTheme.bodyMedium),
                Text(
                  field.column,
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontFamily: 'monospace',
                    color: theme.textTheme.bodySmall?.color?.withValues(
                      alpha: 0.7,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: Space.md),
          Expanded(
            flex: 3,
            child: Text(
              field.value,
              style: theme.textTheme.bodyMedium,
              textAlign: TextAlign.right,
            ),
          ),
        ],
      ),
    );
  }
}
