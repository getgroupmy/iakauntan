import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/repository.dart';
import '../banking/bank_feed.dart';

/// Having the bank send its own statements.
///
/// `0567` built the connection, the credential held so nothing can read
/// it back, and a row per pull — and nothing in the app reached any of
/// it, which is the fault `docs/unreachable.md` exists to catch and
/// which this card is the answer to.
///
/// One row per bank account, because a company banks in several places
/// and each account connects on its own. The statement import on the
/// reconciliation screen is unchanged and stays the way in for a bank
/// with no feed: a feed is a convenience, not a prerequisite.
class BankFeedsCard extends ConsumerWidget {
  const BankFeedsCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final accounts = ref.watch(bankAccountsProvider);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Space.lg),
        child: AsyncView<List<Map<String, dynamic>>>(
          value: accounts,
          onRetry: () => ref.invalidate(bankAccountsProvider),
          builder: (rows) {
            final live = [
              for (final r in rows)
                if (r['is_active'] != false) r,
            ];

            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SectionHeader(
                  'Bring in your bank statements',
                  subtitle:
                      'A connected bank sends its statement on its own, so '
                      'reconciliation has the lines without anybody pasting '
                      'a CSV. Importing by hand still works and is not going '
                      'anywhere.',
                ),
                const SizedBox(height: Space.md),
                if (live.isEmpty)
                  Text(
                    'No bank accounts yet. Add one first, on the '
                    'reconciliation screen.',
                    style: Theme.of(context).textTheme.bodySmall,
                  )
                else
                  for (final a in live) _FeedRow(account: a),
                // Said plainly rather than drawn as an empty picker. The
                // spine is built and asserted; what is missing is the
                // code that talks to a bank, and pretending otherwise
                // would be a form that cannot be submitted.
                if (bankFeedProviders.isEmpty) ...[
                  const SizedBox(height: Space.md),
                  Text(
                    'No bank is connectable yet. Everything around the feed '
                    'is built — where the connection lives, how the '
                    'credential is held, and a record of every pull — and '
                    'what is left is one piece of code per bank. Until then '
                    'these rows show what a feed would say.',
                    style: TextStyle(
                      fontSize: 12,
                      color: context.scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ],
            );
          },
        ),
      ),
    );
  }
}

/// One account, and whatever its feed is doing.
class _FeedRow extends ConsumerWidget {
  const _FeedRow({required this.account});

  final Map<String, dynamic> account;

  String get _id => '${account['id']}';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(bankFeedProvider(_id)).valueOrNull;
    final scheme = Theme.of(context).colorScheme;
    final colors = context.colors;

    // Quiet is its own state and not one the database records. A feed
    // that says Connected and last pulled three weeks ago is broken in
    // the way that costs a month end, and nothing sets `failed` unless
    // a pull ran and failed.
    final quiet = feedHasGoneQuiet(status);
    final (icon, colour) = switch ((feedNeedsAttention(status), quiet)) {
      (true, _) => (Icons.error_outline, colors.danger),
      (_, true) => (Icons.schedule_outlined, colors.warning),
      _ when feedIsLive(status) => (Icons.sync, colors.success),
      _ when hasFeed(status) => (Icons.pause_circle_outline,
          scheme.onSurfaceVariant),
      _ => (Icons.link_off, scheme.onSurfaceVariant),
    };

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Space.sm),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: colour),
          const SizedBox(width: Space.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${account['name']} · ${feedHeadline(status)}',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 2),
                Text(
                  quiet
                      ? 'Nothing has arrived for two days. Check the bank.'
                      : feedDetail(status),
                  style: TextStyle(
                    fontSize: 12,
                    color: quiet ? colors.warning : scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          if (hasFeed(status)) ...[
            TextButton(
              onPressed: () => _showRuns(context, ref),
              child: const Text('Every pull'),
            ),
            TextButton(
              onPressed: () => _pause(context, ref, status),
              child: Text(pauseLabel(status)),
            ),
            TextButton(
              onPressed: () => _disconnect(context, ref),
              child: const Text('Disconnect'),
            ),
          ],
        ],
      ),
    );
  }

  /// Every pull, which is the point of recording them.
  ///
  /// `0567` keeps a row per pull because a feed's failure mode is
  /// silence, and the status line can only say what the last one did.
  /// The history is where "it has been importing nothing for a
  /// fortnight" is visible, and a run log nothing draws is a run log
  /// that proves nothing.
  Future<void> _showRuns(BuildContext context, WidgetRef ref) =>
      showDialog<void>(
        context: context,
        builder: (_) => _RunsDialog(bankAccountId: _id, name: '${account['name']}'),
      );

  Future<void> _pause(
    BuildContext context,
    WidgetRef ref,
    Map<String, dynamic>? status,
  ) async {
    final pausing = feedIsLive(status);
    final ok = await runWithFeedback(
      context,
      doing: pausing ? 'pause the feed' : 'start the feed',
      successMessage: pausing ? 'Paused.' : 'Running again.',
      action: () =>
          ref.read(repoProvider)!.setBankFeedPaused(_id, pausing),
    );
    if (ok) _refresh(ref);
  }

  Future<void> _disconnect(BuildContext context, WidgetRef ref) async {
    final go = await confirm(
      context,
      title: 'Disconnect ${account['name']}?',
      message: 'The stored credential is deleted and nothing more '
          'arrives on its own. What has already been imported stays, '
          'and so does the record of when it came in.',
      confirmLabel: 'Disconnect',
    );
    if (!go || !context.mounted) return;
    final ok = await runWithFeedback(
      context,
      doing: 'disconnect the feed',
      successMessage: 'Disconnected.',
      // `disconnect_bank_feed` refuses anybody who is not an owner or
      // administrator, in words written to be read, and
      // `runWithFeedback` shows what came back. The button is drawn for
      // everybody: hiding it would leave somebody wondering why their
      // own bank cannot be disconnected.
      action: () => ref.read(repoProvider)!.disconnectBankFeed(_id),
    );
    if (ok) _refresh(ref);
  }

  void _refresh(WidgetRef ref) {
    ref.invalidate(bankFeedProvider(_id));
    ref.invalidate(bankFeedRunsProvider(_id));
  }
}

/// The last twenty pulls on one account.
class _RunsDialog extends ConsumerWidget {
  const _RunsDialog({required this.bankAccountId, required this.name});

  final String bankAccountId;
  final String name;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final runs = ref.watch(bankFeedRunsProvider(bankAccountId));
    final scheme = Theme.of(context).colorScheme;

    return AlertDialog(
      title: Text('$name · every pull'),
      content: SizedBox(
        width: 520,
        child: AsyncView<List<Map<String, dynamic>>>(
          value: runs,
          onRetry: () => ref.invalidate(bankFeedRunsProvider(bankAccountId)),
          builder: (rows) {
            if (rows.isEmpty) {
              return const Text('Nothing has been pulled yet.');
            }
            return SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final r in rows)
                    ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(
                        r['ok'] == true
                            ? Icons.check_circle_outline
                            : Icons.error_outline,
                        size: 18,
                        color: r['ok'] == true
                            ? context.colors.success
                            : context.colors.danger,
                      ),
                      title: Text(
                        Fmt.dateTime(
                          DateTime.tryParse('${r['started_at']}'),
                        ),
                        style: const TextStyle(fontSize: 13),
                      ),
                      subtitle: Text(
                        r['ok'] == true
                            // Skipped is the number that says it is
                            // working: an overlapping window re-delivered
                            // should skip everything and import nothing.
                            ? '${r['imported']} imported, '
                                '${r['skipped']} already had'
                            : '${r['error'] ?? 'It failed and said nothing'}',
                        style: TextStyle(
                          fontSize: 12,
                          color: r['ok'] == true
                              ? scheme.onSurfaceVariant
                              : context.colors.danger,
                        ),
                      ),
                    ),
                ],
              ),
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
      ],
    );
  }
}
