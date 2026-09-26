import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../shared/file_viewer.dart';
import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/skeletons.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';

/// What every company has told us, faults first and worst first.
///
/// The order is the point. A list where a suggestion sits above a
/// system that will not open is a list nobody works down, so the server
/// sorts it and this screen does not re-sort it.
class FeedbackAdminTab extends ConsumerStatefulWidget {
  const FeedbackAdminTab({super.key});

  @override
  ConsumerState<FeedbackAdminTab> createState() => _FeedbackAdminTabState();
}

class _FeedbackAdminTabState extends ConsumerState<FeedbackAdminTab> {
  String? _status = 'new';

  static const _statuses = [
    'new',
    'triaged',
    'planned',
    'in_progress',
    'done',
    'declined',
    'duplicate',
  ];

  @override
  Widget build(BuildContext context) {
    final rows = ref.watch(platformFeedbackProvider(_status));

    return Scaffold(
      appBar: AppBar(
        title: const Text('What people have told us'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: DropdownButton<String?>(
              value: _status,
              underline: const SizedBox.shrink(),
              items: [
                const DropdownMenuItem(value: null, child: Text('Everything')),
                for (final s in _statuses)
                  DropdownMenuItem(value: s, child: Text(Fmt.label(s))),
              ],
              onChanged: (v) => setState(() => _status = v),
            ),
          ),
        ],
      ),
      body: AsyncView(
        value: rows,
        onRetry: () => ref.invalidate(platformFeedbackProvider(_status)),
        skeleton: const ListSkeleton(rows: 6),
        builder: (list) {
          if (list.isEmpty) {
            return const EmptyState(
              icon: Icons.inbox_outlined,
              title: 'Nothing here',
              message: 'No report is in this state.',
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.all(Space.lg),
            itemCount: list.length,
            separatorBuilder: (_, _) => const SizedBox(height: 12),
            itemBuilder: (_, i) => _Row(row: list[i], filter: _status),
          );
        },
      ),
    );
  }
}

class _Row extends ConsumerWidget {
  const _Row({required this.row, required this.filter});

  final Map<String, dynamic> row;
  final String? filter;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final severity = (row['severity'] as num?)?.toInt();
    final isBug = '${row['kind']}' == 'bug';

    return Card(
      child: ExpansionTile(
        leading: Icon(
          isBug ? Icons.bug_report_outlined : Icons.lightbulb_outline,
          // Severity 1 is "nobody can work". It should look like it.
          color: severity == 1 ? context.colors.danger : null,
        ),
        title: Text('${row['title']}'),
        subtitle: Text(
          [
            Fmt.label('${row['kind']}'),
            if (severity != null) 'severity $severity',
            if (row['company'] != null) '${row['company']}',
            '${row['reported_by']}',
            Fmt.date(DateTime.tryParse('${row['created_at']}')),
            if (row['app_version'] != null) 'build ${row['app_version']}',
          ].join(' · '),
        ),
        childrenPadding: const EdgeInsets.fromLTRB(
          Space.lg,
          0,
          Space.lg,
          Space.lg,
        ),
        children: [
          if ((row['body'] as String?)?.isNotEmpty ?? false)
            Align(
              alignment: Alignment.centerLeft,
              child: Text('${row['body']}'),
            ),
          if (row['screen'] != null)
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'On ${row['screen']}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          // The files, which are the whole reason `0660` gave feedback
          // its own read rule rather than reusing the org-scoped
          // attachments table: staff here are in no organization and
          // must still be able to open a screenshot of the fault.
          _ReportFiles(reportId: '${row['id']}'),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final s in const [
                'triaged',
                'planned',
                'in_progress',
                'done',
                'declined',
                'duplicate',
              ])
                OutlinedButton(
                  onPressed: () => _move(context, ref, s),
                  child: Text(Fmt.label(s)),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _move(BuildContext context, WidgetRef ref, String status) async {
    // Every move asks for a line back, because the reporter reads it and
    // a status with no sentence under it tells them nothing. Declining
    // in silence is how people stop reporting.
    final note = await promptForText(
      context,
      title: '${Fmt.label(status)} — what should the reporter be told?',
      label: 'Reply',
      confirmLabel: 'Save',
    );
    if (note == null || !context.mounted) return;

    await runWithFeedback(
      context,
      doing: 'move a report on',
      successMessage: 'Updated',
      action: () => ref
          .read(platformRepoProvider)
          .setFeedbackStatus(row['id'] as String, status, note: note),
    );
    ref.invalidate(platformFeedbackProvider(filter));
  }
}

/// The files somebody attached when they filed the report.
///
/// Fetched when the row is expanded rather than with the list: most
/// reports carry none, and a signed URL per file for a page of reports
/// nobody opened would be a round trip for nothing.
class _ReportFiles extends ConsumerWidget {
  const _ReportFiles({required this.reportId});

  final String reportId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final files = ref.watch(feedbackFilesProvider(reportId));
    return files.when(
      // Quietly, both of them. A report with no files is the common
      // case and must not draw an empty heading; a list that failed to
      // load must not push the triage buttons off the screen behind a
      // red box. The status buttons below are what this row is for.
      loading: () => const SizedBox.shrink(),
      error: (_, __) => const SizedBox.shrink(),
      data: (rows) {
        if (rows.isEmpty) return const SizedBox.shrink();
        return Align(
          alignment: Alignment.centerLeft,
          child: Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              for (final file in rows)
                ActionChip(
                  avatar: const Icon(Icons.attachment, size: 16),
                  label: Text(
                    '${file['file_name']} '
                    '(${Fmt.bytes((file['file_size'] as num?)?.toInt() ?? 0)})',
                  ),
                  onPressed: () async {
                    final repo = ref.read(platformRepoProvider);
                    // In the app, from the bytes. A screenshot attached
                    // to a bug report is somebody's books on their
                    // screen, and a signed URL handed to the external
                    // browser leaves a working link to it in another
                    // application's history.
                    final path = '${file['storage_path']}';
                    await showFileInApp(
                      context,
                      ref,
                      fileName: '${file['file_name'] ?? 'Attachment'}',
                      mimeType: file['mime_type']?.toString(),
                      fetch: () => repo.feedbackFileBytes(path),
                    );
                  },
                ),
            ],
          ),
        );
      },
    );
  }
}
