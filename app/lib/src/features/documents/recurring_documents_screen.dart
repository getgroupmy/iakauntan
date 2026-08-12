import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';

/// Invoices and bills that raise themselves.
///
/// There is no editor here on purpose. A schedule is made from a
/// document that already exists — "Repeat this invoice" on a posted
/// invoice — because everything an invoice can express is already
/// expressible there, and a second editor would only manage some of it.
/// What this screen does is show what is coming, let somebody stop it,
/// and run what is due without waiting for tonight.
class RecurringDocumentsScreen extends ConsumerStatefulWidget {
  const RecurringDocumentsScreen({super.key});

  @override
  ConsumerState<RecurringDocumentsScreen> createState() =>
      _RecurringDocumentsScreenState();
}

class _RecurringDocumentsScreenState
    extends ConsumerState<RecurringDocumentsScreen> {
  bool _busy = false;

  Future<void> _runDue() async {
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final n = await ref.read(repoProvider)!.runRecurringDocuments();
      messenger.showSnackBar(SnackBar(
        content: Text(switch (n) {
          0 => 'Nothing was due',
          1 => 'Raised one document',
          _ => 'Raised $n documents',
        }),
      ));
    } catch (err) {
      messenger.showSnackBar(SnackBar(content: Text('$err')));
    }
    if (mounted) setState(() => _busy = false);
    ref.invalidate(recurringDocumentsProvider);
    refreshLedgerData(ref);
  }

  @override
  Widget build(BuildContext context) {
    final rows = ref.watch(recurringDocumentsProvider);
    final canPost = ref.watch(canPostProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Recurring')),
      floatingActionButton: canPost
          ? FloatingActionButton.extended(
              onPressed: _busy ? null : _runDue,
              icon: const Icon(Icons.play_arrow),
              label: const Text('Run what is due'),
            )
          : null,
      body: AsyncView(
        value: rows,
        onRetry: () => ref.invalidate(recurringDocumentsProvider),
        builder: (list) => list.isEmpty
            ? const EmptyState(
                icon: Icons.event_repeat_outlined,
                title: 'Nothing repeats yet',
                message: 'Open an invoice or a bill that happens every '
                    'month and choose Repeat this document.',
              )
            : ListView.separated(
                padding: const EdgeInsets.only(bottom: 96),
                itemCount: list.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (_, i) => _ScheduleTile(
                  row: list[i],
                  canPost: canPost,
                  onChanged: () =>
                      ref.invalidate(recurringDocumentsProvider),
                ),
              ),
      ),
    );
  }
}

class _ScheduleTile extends ConsumerWidget {
  const _ScheduleTile({
    required this.row,
    required this.canPost,
    required this.onChanged,
  });

  final Map<String, dynamic> row;
  final bool canPost;
  final VoidCallback onChanged;

  /// "Every month", "Every 2 weeks" — the interval only earns a mention
  /// when it is not one.
  String get _cadence {
    final every = Fmt.toInt(row['interval_count']);
    final unit = switch (row['frequency']?.toString()) {
      'daily' => every == 1 ? 'day' : 'days',
      'weekly' => every == 1 ? 'week' : 'weeks',
      'quarterly' => every == 1 ? 'quarter' : 'quarters',
      'yearly' => every == 1 ? 'year' : 'years',
      _ => every == 1 ? 'month' : 'months',
    };
    return every == 1 ? 'Every $unit' : 'Every $every $unit';
  }

  String get _limit {
    final max = row['max_occurrences'];
    if (max != null) {
      final done = Fmt.toInt(row['occurrences']);
      return '$done of ${Fmt.toInt(max)}';
    }
    if (row['end_date'] != null) {
      return 'until ${Fmt.date(Fmt.parseDate(row['end_date']))}';
    }
    return '';
  }

  Future<void> _setActive(WidgetRef ref, BuildContext context, bool on) async {
    await runWithFeedback(
      context,
      action: () => ref
          .read(repoProvider)!
          .saveRecurringDocument(row['id'] as String, {'is_active': on}),
      successMessage: on ? 'Resumed' : 'Paused',
    );
    onChanged();
  }

  Future<void> _delete(WidgetRef ref, BuildContext context) async {
    final ok = await confirm(
      context,
      title: 'Stop this schedule?',
      message: 'Documents it has already raised are left alone. Pause it '
          'instead if you may want it back.',
      confirmLabel: 'Delete',
      destructive: true,
    );
    if (!ok || !context.mounted) return;
    await runWithFeedback(
      context,
      action: () =>
          ref.read(repoProvider)!.deleteRecurringDocument(row['id'] as String),
      successMessage: 'Deleted',
    );
    onChanged();
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final active = row['is_active'] == true;
    final error = row['last_error']?.toString();
    final auto = [
      if (row['auto_post'] == true) 'posts itself',
      if (row['auto_email'] == true) 'emails the customer',
    ].join(' and ');

    return ListTile(
      contentPadding:
          const EdgeInsets.symmetric(horizontal: Space.lg, vertical: Space.xs),
      leading: Icon(
        row['kind'] == 'purchase'
            ? Icons.shopping_bag_outlined
            : Icons.receipt_long_outlined,
        color: active ? null : Theme.of(context).disabledColor,
      ),
      title: Row(children: [
        Flexible(
          child: Text(
            row['name']?.toString() ?? '',
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontWeight: FontWeight.w600,
              color: active ? null : Theme.of(context).disabledColor,
            ),
          ),
        ),
        if (!active) ...[
          const SizedBox(width: Space.sm),
          const StatusChip('paused', compact: true),
        ],
      ]),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            [
              _cadence,
              if (active)
                'next ${Fmt.date(Fmt.parseDate(row['next_run_date']))}',
              _limit,
              if (auto.isNotEmpty) auto,
            ].where((s) => s.isNotEmpty).join(' · '),
            style: const TextStyle(fontSize: 12),
          ),
          // The reason a schedule stopped billing is the thing somebody
          // came to this screen to find out.
          if (error != null && error.isNotEmpty)
            Text(
              'Last run failed: $error',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, color: context.colors.danger),
            ),
        ],
      ),
      isThreeLine: error != null && error.isNotEmpty,
      trailing: !canPost
          ? null
          : PopupMenuButton<String>(
              onSelected: (v) => switch (v) {
                'pause' => _setActive(ref, context, false),
                'resume' => _setActive(ref, context, true),
                _ => _delete(ref, context),
              },
              itemBuilder: (_) => [
                if (active)
                  const PopupMenuItem(value: 'pause', child: Text('Pause'))
                else
                  const PopupMenuItem(value: 'resume', child: Text('Resume')),
                const PopupMenuItem(value: 'delete', child: Text('Delete')),
              ],
            ),
    );
  }
}
