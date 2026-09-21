import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/skeletons.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../shared/attachments_card.dart';
import 'screen_catalogue.dart';

/// Somewhere to say it is broken.
///
/// The service desk in this product is the one a *tenant* runs for its
/// own customers. Nothing pointed the other way, at us, so a person who
/// found a fault in the payroll screen had an e-mail address to guess
/// at.
///
/// No module gate: reporting a fault is not a feature a company buys,
/// and a company that has stopped paying for something is exactly the
/// one most likely to want to say why.
class FeedbackScreen extends ConsumerWidget {
  const FeedbackScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final reports = ref.watch(myFeedbackProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Report a problem'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: FilledButton.icon(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => const _ReportDialog(),
              ),
              icon: const Icon(Icons.add, size: 18),
              label: const Text('New report'),
            ),
          ),
        ],
      ),
      body: AsyncView(
        value: reports,
        onRetry: () => ref.invalidate(myFeedbackProvider),
        skeleton: const ListSkeleton(rows: 6),
        builder: (rows) {
          if (rows.isEmpty) {
            return const EmptyState(
              icon: Icons.bug_report_outlined,
              title: 'Nothing reported yet',
              message:
                  'Something wrong, something missing, or something that '
                  'could be better — all three are worth sending. Pick '
                  'the screen it happened on and we can usually see it '
                  'ourselves.',
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.all(Space.lg),
            itemCount: rows.length,
            separatorBuilder: (_, _) => const SizedBox(height: 12),
            itemBuilder: (_, i) => _ReportTile(row: rows[i]),
          );
        },
      ),
    );
  }
}

class _ReportTile extends ConsumerWidget {
  const _ReportTile({required this.row});

  final Map<String, dynamic> row;

  static const _statusLabels = {
    'new': 'Waiting to be looked at',
    'triaged': 'Read and understood',
    'planned': 'On the list',
    'in_progress': 'Being worked on',
    'done': 'Done',
    'declined': 'Not going to be done',
    'duplicate': 'Already reported',
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = '${row['status']}';
    final note = row['platform_note'] as String?;
    final mine = row['is_mine'] == true;

    return Card(
      child: ExpansionTile(
        title: Text('${row['title']}'),
        subtitle: Text(
          [
            Fmt.label('${row['kind']}'),
            _statusLabels[status] ?? Fmt.label(status),
            Fmt.date(DateTime.tryParse('${row['created_at']}')),
            if (!mine) 'by ${row['reported_by']}',
          ].join(' · '),
        ),
        leading: Icon(
          switch ('${row['kind']}') {
            'feature' => Icons.lightbulb_outline,
            'suggestion' => Icons.tips_and_updates_outlined,
            _ => Icons.bug_report_outlined,
          },
          color: status == 'done' ? context.colors.success : null,
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
          if (row['screen'] != null) ...[
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'On ${row['screen']}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ],
          // What came back. A report that vanishes is a report nobody
          // sends twice.
          if (note != null && note.isNotEmpty) ...[
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(Space.md),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(note),
            ),
          ],
          const SizedBox(height: 12),
          AttachmentsCard(
            table: 'feedback_reports',
            recordId: row['id'] as String,
            title: 'Screenshots',
            subtitle: mine
                ? 'A picture of what you saw is usually worth more than '
                      'the description'
                : null,
            // Only the person who raised it. Somebody else adding a
            // picture to your report is a conversation, and this is not
            // one.
            canAttach: mine,
          ),
        ],
      ),
    );
  }
}

class _ReportDialog extends ConsumerStatefulWidget {
  const _ReportDialog();

  @override
  ConsumerState<_ReportDialog> createState() => _ReportDialogState();
}

class _ReportDialogState extends ConsumerState<_ReportDialog> {
  final _title = TextEditingController();
  final _body = TextEditingController();
  String _kind = 'bug';
  int _severity = 3;

  // Module, then the part of it, then the screen. Null at each level
  // means "not chosen yet", and the two below reset when the one above
  // changes — a sub-module left over from the previous module is how a
  // picker sends back an answer nobody meant.
  ScreenModule? _module;
  ScreenArea? _area;
  AppScreen? _screen;

  @override
  void dispose() {
    _title.dispose();
    _body.dispose();
    super.dispose();
  }

  /// What goes in the report: something a person can read and an address
  /// we can open. Null until a screen is chosen, and null is allowed —
  /// see `kSomewhereElse`.
  String? get _where => _screen?.toString();

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Tell us'),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(
                    value: 'bug',
                    label: Text('Wrong'),
                    icon: Icon(Icons.bug_report_outlined, size: 16),
                  ),
                  ButtonSegment(
                    value: 'feature',
                    label: Text('Missing'),
                    icon: Icon(Icons.lightbulb_outline, size: 16),
                  ),
                  ButtonSegment(
                    value: 'suggestion',
                    label: Text('An idea'),
                    icon: Icon(Icons.tips_and_updates_outlined, size: 16),
                  ),
                ],
                selected: {_kind},
                onSelectionChanged: (v) => setState(() => _kind = v.first),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _title,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: 'In one line',
                  hintText: 'The employer EPF column is blank',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _body,
                minLines: 3,
                maxLines: 6,
                decoration: const InputDecoration(
                  labelText: 'What happened, and what you expected',
                ),
              ),
              const SizedBox(height: 16),
              Text(
                'Where it happened',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 8),
              DropdownButtonFormField<ScreenModule?>(
                key: const ValueKey('feedback-module'),
                initialValue: _module,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Module'),
                items: [
                  for (final m in appScreenCatalogue)
                    DropdownMenuItem(value: m, child: Text(m.label)),
                  const DropdownMenuItem(value: null, child: Text(kSomewhereElse)),
                ],
                onChanged: (m) => setState(() {
                  _module = m;
                  _area = null;
                  _screen = null;
                }),
              ),
              if (_module != null) ...[
                const SizedBox(height: 12),
                DropdownButtonFormField<ScreenArea>(
                  key: const ValueKey('feedback-area'),
                  initialValue: _area,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Part of it'),
                  items: [
                    for (final a in _module!.areas)
                      DropdownMenuItem(value: a, child: Text(a.label)),
                  ],
                  onChanged: (a) => setState(() {
                    _area = a;
                    _screen = null;
                  }),
                ),
              ],
              if (_area != null) ...[
                const SizedBox(height: 12),
                DropdownButtonFormField<AppScreen>(
                  key: const ValueKey('feedback-screen'),
                  initialValue: _screen,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Screen'),
                  items: [
                    for (final sc in _area!.screens)
                      DropdownMenuItem(value: sc, child: Text(sc.label)),
                  ],
                  onChanged: (sc) => setState(() => _screen = sc),
                ),
              ],
              const SizedBox(height: 6),
              Text(
                _where ?? 'Naming the screen is the difference between a '
                    'report we can act on and one we have to write back '
                    'about. Leave it on Somewhere else if none of these '
                    'is it.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              // Only on a fault. A severity on a suggestion sorts it in
              // among the things that are actually broken.
              if (_kind == 'bug') ...[
                const SizedBox(height: 16),
                Text(
                  'How badly it is in the way',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                Slider(
                  value: _severity.toDouble(),
                  min: 1,
                  max: 4,
                  divisions: 3,
                  label: switch (_severity) {
                    1 => 'Nobody can work',
                    2 => 'A real problem, with a way round it',
                    3 => 'Annoying',
                    _ => 'Untidy',
                  },
                  onChanged: (v) => setState(() => _severity = v.round()),
                ),
              ],
              const SizedBox(height: 8),
              Text(
                'Read by us and by your own administrators — not by '
                'other companies.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () async {
            if (_title.text.trim().isEmpty) return;
            final repo = ref.read(repoProvider);
            if (repo == null) return;
            final done = await runWithFeedback(
              context,
              doing: 'report a problem',
              successMessage: 'Sent — thank you',
              action: () => repo.reportFeedback(
                title: _title.text.trim(),
                kind: _kind,
                body: _body.text.trim().isEmpty ? null : _body.text.trim(),
                screen: _where,
                severity: _kind == 'bug' ? _severity : null,
              ),
            );
            ref.invalidate(myFeedbackProvider);
            if (done && context.mounted) Navigator.pop(context);
          },
          child: const Text('Send'),
        ),
      ],
    );
  }
}
