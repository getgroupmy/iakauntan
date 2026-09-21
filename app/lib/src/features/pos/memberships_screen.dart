import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/skeletons.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
// `RepoMemberships` is an extension, and a Dart extension is only in
// scope where its declaring library is imported.
import '../../data/repository.dart';

/// Who is on a membership, what they have left, and who nobody is
/// billing.
///
/// 0218 built all of this and nothing ever called it. The subsystem has
/// been sitting in the database — offers, subscriptions, a session
/// ledger and five functions granted to `authenticated` — reachable
/// only by somebody writing SQL. This is the screen that reaches it.
///
/// ## The gaps go at the top, not behind a tab
///
/// `start_membership` deliberately does not fail when the cashier
/// cannot post: refusing the whole membership would leave somebody who
/// has just paid with nothing, so the subscription is created and the
/// missing renewal schedule is *reported* instead. That trade is only
/// honest if the report is seen. `membership_billing_gaps` returns
/// active memberships with no schedule behind them, and a shop that
/// discovers those in March has lost a quarter of the revenue — so the
/// banner sits above the list rather than waiting to be found.
///
/// ## Nothing here computes an entitlement
///
/// "Three classes left" is `membership_balance`, worked out in SQL from
/// the session ledger against a period counted from the day the member
/// joined. A screen that counted rows itself would be a second
/// implementation of the membership rules, and the visits it disagreed
/// about would be exactly the ones being argued over at the counter.
///
/// Unlimited is null, not a large number, and is shown as unlimited.
/// Defaulting it to zero would tell somebody with an unlimited gym
/// membership that they have nothing left.
class MembershipsScreen extends ConsumerStatefulWidget {
  const MembershipsScreen({super.key});

  @override
  ConsumerState<MembershipsScreen> createState() => _MembershipsScreenState();
}

class _MembershipsScreenState extends ConsumerState<MembershipsScreen> {
  String _status = 'active';

  static const _statuses = <String, String>{
    'active': 'Active',
    'paused': 'Paused',
    'cancelled': 'Cancelled',
    'expired': 'Expired',
    'all': 'All',
  };

  Future<void> _setStatus(Map<String, dynamic> sub, String status) async {
    final ok = await runWithFeedback(
      context,
      action: () =>
          ref.read(repoProvider)!.setMembershipStatus(sub['id'] as String, status),
      successMessage: 'Membership ${_statuses[status]!.toLowerCase()}.',
    );
    if (ok && mounted) {
      ref.invalidate(membershipSubscriptionsProvider);
      ref.invalidate(membershipBillingGapsProvider);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Memberships are their own module since 0231, and the server
    // agrees: every function below is gated on `memberships` rather
    // than on the till. A company that has not bought it would get a
    // screen of buttons that come back refused.
    if (!moduleEnabled(ref, 'memberships')) {
      return Scaffold(
        appBar: AppBar(title: const Text('Memberships')),
        body: const EmptyState(
          icon: Icons.card_membership_outlined,
          title: 'Memberships is not switched on',
          message:
              'This company does not have the memberships module, or has '
              'put it away in settings.',
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Memberships')),
      body: Column(
        children: [
          const _BillingGaps(),
          FilterBar(
            child: SegmentedButton<String>(
              segments: [
                for (final e in _statuses.entries)
                  ButtonSegment(value: e.key, label: Text(e.value)),
              ],
              selected: {_status},
              showSelectedIcon: false,
              onSelectionChanged: (s) => setState(() => _status = s.first),
            ),
          ),
          Expanded(
            child: AsyncView<List<Map<String, dynamic>>>(
              value: ref.watch(membershipSubscriptionsProvider(_status)),
              onRetry: () =>
                  ref.invalidate(membershipSubscriptionsProvider(_status)),
              skeleton: const ListSkeleton(
                rows: 6,
                leading: false,
                subtitle: false,
              ),
              builder: (subs) {
                if (subs.isEmpty) {
                  return EmptyState(
                    icon: Icons.card_membership_outlined,
                    title: _status == 'all'
                        ? 'Nobody is on a membership yet'
                        : 'No ${_statuses[_status]!.toLowerCase()} memberships',
                    message:
                        'A membership starts from the sale that paid for it, '
                        'at the till.',
                  );
                }
                return RefreshIndicator(
                  onRefresh: () async {
                    ref.invalidate(membershipSubscriptionsProvider(_status));
                    ref.invalidate(membershipBillingGapsProvider);
                  },
                  child: ListView.builder(
                    padding: const EdgeInsets.only(bottom: Space.xxl),
                    itemCount: subs.length,
                    itemBuilder: (_, i) => _SubscriptionTile(
                      sub: subs[i],
                      onStatus: (s) => _setStatus(subs[i], s),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// The memberships nobody is billing.
///
/// Silent when there are none and silent while it loads — an empty
/// banner or a spinner above the list would make "everything is fine"
/// look like something to read.
class _BillingGaps extends ConsumerWidget {
  const _BillingGaps();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final gaps = ref.watch(membershipBillingGapsProvider);
    return gaps.maybeWhen(
      data: (rows) {
        if (rows.isEmpty) return const SizedBox.shrink();
        final scheme = Theme.of(context).colorScheme;
        return Container(
          width: double.infinity,
          margin: const EdgeInsets.fromLTRB(Space.lg, Space.md, Space.lg, 0),
          padding: const EdgeInsets.all(Space.md),
          decoration: BoxDecoration(
            color: scheme.errorContainer.withValues(alpha: 0.5),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.receipt_long_outlined,
                      size: 18, color: scheme.onErrorContainer),
                  const SizedBox(width: Space.sm),
                  Expanded(
                    child: Text(
                      rows.length == 1
                          ? '1 membership has no renewal schedule'
                          : '${rows.length} memberships have no renewal '
                                'schedule',
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        color: scheme.onErrorContainer,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                'These are being used but not invoiced. A member whose '
                'first sale was rung up by somebody without posting rights '
                'lands here.',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: scheme.onErrorContainer,
                ),
              ),
              const SizedBox(height: Space.sm),
              for (final g in rows.take(5))
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    '${g['member'] ?? '—'} · ${g['membership'] ?? '—'} · '
                    'since ${Fmt.date(Fmt.parseDate(g['started_on']))}',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: scheme.onErrorContainer,
                    ),
                  ),
                ),
              if (rows.length > 5)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    'and ${rows.length - 5} more',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: scheme.onErrorContainer,
                    ),
                  ),
                ),
            ],
          ),
        );
      },
      orElse: () => const SizedBox.shrink(),
    );
  }
}

class _SubscriptionTile extends StatelessWidget {
  const _SubscriptionTile({required this.sub, required this.onStatus});

  final Map<String, dynamic> sub;
  final ValueChanged<String> onStatus;

  @override
  Widget build(BuildContext context) {
    final contact = sub['contacts'] as Map<String, dynamic>?;
    final offer = sub['pos_memberships'] as Map<String, dynamic>?;
    final status = (sub['status'] ?? '') as String;
    final id = sub['id'] as String;

    return Card(
      margin: const EdgeInsets.fromLTRB(Space.lg, Space.sm, Space.lg, 0),
      child: Padding(
        padding: const EdgeInsets.all(Space.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        (contact?['name'] ?? 'Unknown member') as String,
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                      Text(
                        '${offer?['name'] ?? '—'} · '
                        '${(offer?['period'] ?? '') as String}',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                StatusChip(status, compact: true),
                _StatusMenu(status: status, onSelected: onStatus),
              ],
            ),
            const SizedBox(height: Space.sm),
            _Balance(subscriptionId: id),
            if (sub['recurring_document_id'] == null && status == 'active')
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  'No renewal schedule',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.error,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// What is left this period, straight from `membership_balance`.
///
/// One request per row, which is a real cost and a deliberate one. The
/// balance depends on a period counted from each member's own start
/// date, so there is no single query that answers it for a page of
/// them without reimplementing `app.membership_period` in the client —
/// which is the arithmetic this screen most wants to avoid owning. The
/// provider is `autoDispose` and the list is lazy, so only the rows a
/// person is actually looking at ask.
class _Balance extends ConsumerWidget {
  const _Balance({required this.subscriptionId});

  final String subscriptionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final balance = ref.watch(membershipBalanceProvider(subscriptionId));
    return balance.maybeWhen(
      data: (row) {
        if (row == null) return const SizedBox.shrink();
        final included = row['included'];
        final used = row['used'] ?? 0;
        final remaining = row['remaining'];
        // Null included is unlimited, which is not zero. See the class
        // comment: the difference matters to the person being told.
        final text = included == null
            ? '$used used this period · unlimited'
            : '$used of $included used · $remaining left';
        return Row(
          children: [
            Icon(
              Icons.confirmation_number_outlined,
              size: 16,
              color: Theme.of(context).colorScheme.outline,
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                '$text · '
                '${Fmt.date(Fmt.parseDate(row['period_start']))} – '
                '${Fmt.date(Fmt.parseDate(row['period_end']))}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ],
        );
      },
      orElse: () => const SizedBox.shrink(),
    );
  }
}

class _StatusMenu extends StatelessWidget {
  const _StatusMenu({required this.status, required this.onSelected});

  final String status;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) {
    // Only the moves that make sense from here. Offering "cancel" on a
    // cancelled membership is a button whose only outcome is a refusal
    // somebody has to interpret.
    final options = <String, String>{
      if (status == 'active') 'paused': 'Pause',
      if (status == 'paused') 'active': 'Resume',
      if (status != 'cancelled') 'cancelled': 'Cancel',
    };
    if (options.isEmpty) return const SizedBox.shrink();
    return PopupMenuButton<String>(
      tooltip: 'Change membership',
      onSelected: onSelected,
      itemBuilder: (_) => [
        for (final e in options.entries)
          PopupMenuItem(value: e.key, child: Text(e.value)),
      ],
    );
  }
}
