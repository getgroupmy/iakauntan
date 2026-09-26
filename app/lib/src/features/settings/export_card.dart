import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/download.dart';
import '../../core/error_text.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/firms_repository.dart';

/// Taking the whole company out of this system.
///
/// This exists so that everything else about ownership is trustworthy. A
/// handover here moves one membership row and touches no data, which is
/// the right design and is only worth anything if leaving altogether is
/// also possible. An accountant asked to put forty clients on a platform
/// they cannot get them off is right to say no.
///
/// The work is done in the browser, one table at a time, because a whole
/// company can be hundreds of thousands of rows and building the file on
/// the server would mean holding all of it in memory to answer one
/// request. The counter is not decoration: an export of a real company
/// takes a while, and a button that appears to do nothing for a minute
/// gets pressed again.
class ExportCard extends ConsumerStatefulWidget {
  const ExportCard({super.key, required this.canAdmin});

  final bool canAdmin;

  @override
  ConsumerState<ExportCard> createState() => _ExportCardState();
}

class _ExportCardState extends ConsumerState<ExportCard> {
  bool _running = false;
  String _progress = '';

  @override
  Widget build(BuildContext context) {
    if (!widget.canAdmin) return const SizedBox.shrink();

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Space.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SectionHeader(
              'Take your data with you',
              subtitle:
                  'Everything this company holds, as one JSON file, '
                  'whenever you want it',
            ),
            Text(
              'Every table with this company\'s data in it, exported '
              'straight from the database rather than from what a screen '
              'happens to be showing. Credentials you gave us to file '
              'e-Invoices or read receipts are not included, and neither '
              'is anything about your subscription — those are ours to '
              'hold, not yours to move.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                FilledButton.icon(
                  onPressed: _running ? null : _run,
                  icon: const Icon(Icons.download_outlined, size: 18),
                  label: Text(_running ? 'Exporting…' : 'Export everything'),
                ),
                const SizedBox(width: 12),
                if (_progress.isNotEmpty)
                  Expanded(
                    child: Text(
                      _progress,
                      style: Theme.of(context).textTheme.bodySmall,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
            ),
            if (_running) ...[
              const SizedBox(height: 12),
              const LinearProgressIndicator(),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _run() async {
    final orgId = ref.read(orgIdProvider);
    if (orgId == null) return;
    final org = ref.read(currentOrgProvider).valueOrNull;
    final repo = ref.read(firmsRepoProvider);

    setState(() {
      _running = true;
      _progress = 'Asking what there is…';
    });

    try {
      final manifest = await repo.exportManifest(orgId);
      final data = <String, dynamic>{};
      var done = 0;

      for (final entry in manifest) {
        final table = '${entry['table_name']}';
        if (mounted) {
          setState(() {
            _progress = '$table (${++done} of ${manifest.length})';
          });
        }
        data[table] = await repo.exportTable(orgId, table);
      }

      final payload = <String, dynamic>{
        'company': org?.name,
        'exported_at': DateTime.now().toUtc().toIso8601String(),
        // What was left out, said in the file rather than only in a
        // migration header: somebody reading this a year from now
        // should not have to wonder whether a missing table means a
        // missing feature or a deliberate exclusion.
        'not_included':
            'Credentials held on this company\'s behalf, its module '
            'entitlements and scanning balance, and columns whose name '
            'marks them as secret (shown as ***).',
        'tables': data,
      };

      final name =
          '${(org?.name ?? 'company').replaceAll(RegExp(r'[^A-Za-z0-9]+'), '-')}'
          '-${DateTime.now().toIso8601String().substring(0, 10)}.json';

      final saved = await saveTextFile(
        name,
        'application/json',
        const JsonEncoder.withIndent('  ').convert(payload),
      );

      if (!mounted) return;
      setState(() {
        _progress = saved
            ? 'Saved as $name'
            // On Android and iOS there is nowhere to put a file without
            // a plugin and a pile of storage permissions, and a file
            // this size will not go on a clipboard. Saying so beats a
            // button that silently does nothing.
            : 'Exports are downloaded from the web app; '
                  'open ${Uri.base.host} in a browser to save the file.';
      });
    } catch (err) {
      if (!mounted) return;
      setState(() => _progress = errorText(err));
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }
}
