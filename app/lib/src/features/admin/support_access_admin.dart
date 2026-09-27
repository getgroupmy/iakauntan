import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/skeletons.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';

/// Every support session, open and closed. `0719`.
///
/// This page is the record, not the control: a session is STARTED from
/// the company it is about, on the Organizations page, because a reason
/// typed next to a name is a reason about that company. What is here is
/// the list — who read whose books, when, why, and whether they are
/// still in there.
///
/// It reads as a log on purpose. A platform that can enter a customer's
/// books should be able to show, on one screen, every time it has.
class SupportAccessAdminTab extends ConsumerWidget {
  const SupportAccessAdminTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sessions = ref.watch(platformSupportAccessProvider);

    return AsyncView<List<Map<String, dynamic>>>(
      value: sessions,
      onRetry: () => ref.invalidate(platformSupportAccessProvider),
      skeleton: const ListSkeleton(rows: 6),
      builder: (rows) {
        if (rows.isEmpty) {
          return const EmptyState(
            icon: Icons.visibility_outlined,
            title: 'Nobody has read a customer’s books',
            message: 'A support session is started from the company it is '
                'about, on the Organizations page. Every one of them '
                'appears here afterwards.',
          );
        }
        return ListView.separated(
          padding: const EdgeInsets.all(Space.lg),
          itemCount: rows.length,
          separatorBuilder: (_, __) => const Divider(height: 1),
          itemBuilder: (_, i) => _SessionTile(session: rows[i]),
        );
      },
    );
  }
}

class _SessionTile extends ConsumerWidget {
  const _SessionTile({required this.session});

  final Map<String, dynamic> session;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final open = isSessionOpen(session, DateTime.now());
    final granted = Fmt.parseDate(session['granted_at']);

    return ListTile(
      key: ValueKey('support-${session['id']}'),
      contentPadding: EdgeInsets.zero,
      leading: Icon(
        open ? Icons.visibility : Icons.visibility_off_outlined,
        size: 20,
        color: open ? context.colors.warning : null,
      ),
      title: Text('${session['org_name']}'),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            [
              '${session['admin_name']}',
              if (granted != null) Fmt.dateTime(granted),
              sessionState(session, DateTime.now()),
            ].join(' · '),
          ),
          const SizedBox(height: 2),
          // The reason, in full and never truncated. It is the whole
          // difference between support and a back door, and a reason
          // nobody can read afterwards is a reason nobody gave.
          Text(
            '${session['reason']}',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: context.scheme.onSurfaceVariant,
                ),
          ),
        ],
      ),
      trailing: open
          ? TextButton(
              key: ValueKey('support-end-${session['id']}'),
              onPressed: () async {
                final ok = await runWithFeedback(
                  context,
                  doing: 'ending a support session',
                  action: () => ref
                      .read(platformRepoProvider)
                      .endSupportAccess('${session['id']}'),
                  successMessage: 'Ended',
                );
                if (ok) {
                  ref.invalidate(platformSupportAccessProvider);
                  ref.invalidate(mySupportAccessProvider);
                }
              },
              child: const Text('End it'),
            )
          : null,
      isThreeLine: true,
    );
  }
}

/// Whether a session is still open, now.
///
/// Three things end one and the list has to agree with the database on
/// all three: it was ended by hand, it expired, or neither. Reading
/// only `ended_at` shows an expired session as live for as long as
/// nobody presses anything — and the row would then offer an "End it"
/// button for something already over.
bool isSessionOpen(Map<String, dynamic> session, DateTime now) {
  if (session['ended_at'] != null) return false;
  final expires = Fmt.parseDate(session['expires_at']);
  if (expires == null) return false;
  return expires.isAfter(now);
}

/// What to say about where a session stands.
String sessionState(Map<String, dynamic> session, DateTime now) {
  if (session['ended_at'] != null) return 'ended';
  final expires = Fmt.parseDate(session['expires_at']);
  if (expires == null) return 'ended';
  if (!expires.isAfter(now)) return 'expired';
  final left = expires.difference(now);
  if (left.inMinutes < 60) return '${left.inMinutes} min left';
  return 'until ${Fmt.dateTime(expires)}';
}

/// Said on every screen, for as long as a support session is open.
///
/// The whole safety of support access rests on the person using it
/// knowing they are using it. A platform administrator who forgets they
/// are inside a customer's books is one careless save away from writing
/// in them -- and `app.org_role` hands them `auditor`, which reads
/// everything, so nothing else on the screen will look unusual. This
/// banner is what makes it look unusual.
///
/// Above the whole shell rather than on one screen, for the reason the
/// maintenance banner is: the screen somebody is on when they realise
/// is not predictable.
class SupportAccessBanner extends ConsumerWidget {
  const SupportAccessBanner({super.key, required this.sessions});

  /// The open sessions this administrator holds. Never empty -- the
  /// shell does not draw the banner at all when it is.
  final List<Map<String, dynamic>> sessions;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colour = context.colors.warning;
    final one = sessions.length == 1 ? sessions.first : null;

    return Material(
      color: colour.withValues(alpha: 0.12),
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: Space.lg,
            vertical: Space.sm,
          ),
          child: Row(
            children: [
              Icon(Icons.visibility_outlined, size: 18, color: colour),
              const SizedBox(width: Space.sm),
              Expanded(
                child: Text(
                  supportBannerText(sessions, DateTime.now()),
                  style: const TextStyle(fontSize: 13),
                ),
              ),
              // One session has an unambiguous thing to do: get out of
              // it. Several do not -- "Leave" would have to guess which,
              // and ending all of them because somebody meant one is
              // the kind of surprise this banner exists to prevent -- so
              // the button goes to the page where each is listed.
              if (one != null)
                TextButton(
                  key: const ValueKey('support-banner-leave'),
                  onPressed: () async {
                    final ok = await runWithFeedback(
                      context,
                      doing: 'leaving a support session',
                      action: () => ref
                          .read(platformRepoProvider)
                          .endSupportAccess('${one['id']}'),
                      successMessage: 'Left',
                    );
                    if (ok) {
                      ref.invalidate(mySupportAccessProvider);
                      ref.invalidate(platformSupportAccessProvider);
                    }
                  },
                  child: const Text('Leave'),
                )
              else
                TextButton(
                  key: const ValueKey('support-banner-open'),
                  onPressed: () => context.go('/admin/support-access'),
                  child: const Text('Show them'),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// What the banner says.
///
/// Names the company, because "you have support access" without saying
/// to what is no use to somebody with three companies open in three
/// tabs. Several sessions name a count instead: the list would not fit
/// on a phone, and the page behind "Show them" has it in full.
String supportBannerText(List<Map<String, dynamic>> sessions, DateTime now) {
  if (sessions.length == 1) {
    final s = sessions.first;
    return 'You are in ${s['org_name']} on support access '
        '— ${sessionState(s, now)}.';
  }
  return 'You are on support access in ${sessions.length} companies.';
}
