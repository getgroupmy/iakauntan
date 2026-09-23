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
import 'scan_actions.dart';
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

          // `0680` mints this when a scan fails and tells the person to
          // quote it. Shown only where there is one, and only on a
          // failure — a reference beside a scan that worked is an
          // identifier somebody would quote about nothing.
          if ((entry.logRef ?? '').isNotEmpty) ...[
            const SizedBox(height: Space.sm),
            _LogReference(reference: entry.logRef!),
          ],

          if (entry.hasImage) ...[
            const SizedBox(height: Space.md),
            OutlinedButton.icon(
              key: const ValueKey('scan-view-image'),
              onPressed: () => _openImage(context, ref),
              icon: const Icon(Icons.image_outlined, size: 18),
              label: const Text('View the image'),
            ),
          ],

          // `0698`. What can still be DONE with this, rather than only
          // what was done to it. Above the fields on purpose: somebody
          // who has scrolled the reading and found it wrong should not
          // have to scroll back to act on that.
          _Actions(entry: entry, reading: reading.valueOrNull),

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

/// Build it, read it again, or read it with somebody else.
///
/// `0698`. Three things that were missing from a sheet that could only
/// describe. Each is hidden rather than disabled when it cannot apply,
/// because a greyed-out button is a question the screen refuses to
/// answer -- and the sentence that WOULD answer it is shown instead
/// where there is one.
class _Actions extends ConsumerStatefulWidget {
  const _Actions({required this.entry, required this.reading});

  final ScanInboxEntry entry;

  /// Null while the reading is still loading, and also when there is
  /// none. The difference does not matter here: neither is something
  /// to build a record from yet.
  final OcrExtraction? reading;

  @override
  ConsumerState<_Actions> createState() => _ActionsState();
}

class _ActionsState extends ConsumerState<_Actions> {
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final entry = widget.entry;
    final ocr = ref.watch(ocrStatusProvider).valueOrNull;
    final refusal = rescanRefusal(entry);
    final choices = refusal != null
        ? const <OcrProvider>[]
        : rescanChoices(ocr, isPdf: entry.mimeType == 'application/pdf');

    // Already became something. Offering to build a second record from
    // the same paper is how a bill gets entered twice, and `0628`'s
    // duplicate check is a warning rather than a wall -- so the offer
    // is simply not made.
    final canCreate = widget.reading != null &&
        entry.attachmentId != null &&
        entry.postedTable == null;

    if (!canCreate && refusal == null && choices.isEmpty) {
      return const SizedBox.shrink();
    }

    return Padding(
      padding: const EdgeInsets.only(top: Space.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (canCreate)
            FilledButton.icon(
              key: const ValueKey('scan-create-from'),
              onPressed: _busy ? null : _create,
              icon: const Icon(Icons.playlist_add_check, size: 18),
              label: const Text('Create it from what was read'),
            ),
          if (refusal != null)
            Padding(
              padding: const EdgeInsets.only(top: Space.sm),
              child: Text(
                refusal,
                key: const ValueKey('scan-rescan-refusal'),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            )
          else ...[
            const SizedBox(height: Space.sm),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    key: const ValueKey('scan-read-again'),
                    onPressed: _busy ? null : () => _rescan(null),
                    icon: const Icon(Icons.refresh, size: 18),
                    label: const Text('Read it again'),
                  ),
                ),
                if (choices.isNotEmpty) ...[
                  const SizedBox(width: Space.sm),
                  // A menu rather than a second dialog. The choice is
                  // short, it is a list of names, and the price is the
                  // thing somebody needs to see beside each one.
                  PopupMenuButton<String>(
                    key: const ValueKey('scan-read-with'),
                    tooltip: 'Read it with another reader',
                    enabled: !_busy,
                    onSelected: _rescan,
                    itemBuilder: (_) => [
                      for (final p in choices)
                        PopupMenuItem<String>(
                          value: p.code,
                          child: ListTile(
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            title: Text(p.name),
                            subtitle: Text(rescanCost(p, ocr!)),
                          ),
                        ),
                    ],
                    child: const Padding(
                      padding: EdgeInsets.all(Space.sm),
                      child: Icon(Icons.expand_more),
                    ),
                  ),
                ],
              ],
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _create() async {
    setState(() => _busy = true);
    try {
      await createFromScan(context, ref, widget.entry, widget.reading!);
      // The flow navigates to whatever it made, so this sheet is on
      // the way out. Closing it is the caller's job only where it is
      // still there to close.
      if (mounted) Navigator.of(context).maybePop();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _rescan(String? provider) async {
    setState(() => _busy = true);
    try {
      final done =
          await rescanDocument(context, ref, widget.entry, provider: provider);
      if (done && mounted) {
        // A new scan row, so the list behind this sheet is stale and
        // the reading in front of it belongs to the old one.
        ref.invalidate(scanInboxProvider);
        Navigator.of(context).maybePop();
      }
    } finally {
      if (mounted) setState(() => _busy = false);
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

/// The reference to quote when asking what went wrong.
///
/// Selectable, which is the entire point: it exists to be copied into a
/// message to somebody who can look it up, and a code you have to
/// retype off a screen is a code that arrives with a digit wrong.
class _LogReference extends StatelessWidget {
  const _LogReference({required this.reference});

  final String reference;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          Icons.tag,
          size: 16,
          color: theme.textTheme.bodySmall?.color,
        ),
        const SizedBox(width: Space.sm),
        Expanded(
          child: SelectableText.rich(
            TextSpan(
              children: [
                TextSpan(
                  text: 'Quote this if you ask about it: ',
                  style: theme.textTheme.bodySmall,
                ),
                TextSpan(
                  text: reference,
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontFamily: 'monospace',
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
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
