import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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
