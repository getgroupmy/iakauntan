import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/skeletons.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';

/// What is waiting for somebody, on every screen.
///
/// The four things it shows were all already recorded and none of them
/// was ever told to anybody: an e-Invoice LHDN refused, a ticket past
/// its SLA, a claim waiting on a named approver, and the statutory
/// lodgement date coming up. The nightly pass gathers them; this is
/// where a person finds them.
class NotificationBell extends ConsumerWidget {
  const NotificationBell({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // valueOrNull, not value: before a company is chosen the provider
    // holds an error rather than a number, and a bell is not worth
    // taking a screen down for.
    final unread = ref.watch(unreadNotificationsProvider).valueOrNull ?? 0;
    final scheme = Theme.of(context).colorScheme;

    return IconButton(
      tooltip: unread == 0 ? 'Nothing waiting' : '$unread waiting',
      onPressed: () => showNotificationsSheet(context, ref),
      icon: Badge(
        isLabelVisible: unread > 0,
        backgroundColor: scheme.error,
        label: Text(unread > 99 ? '99+' : '$unread'),
        child: Icon(unread > 0
            ? Icons.notifications_active_outlined
            : Icons.notifications_none),
      ),
    );
  }
}

Future<void> showNotificationsSheet(BuildContext context, WidgetRef ref) {
  return showDialog<void>(
    context: context,
    builder: (_) => const _NotificationsDialog(),
  );
}

class _NotificationsDialog extends ConsumerStatefulWidget {
  const _NotificationsDialog();

  @override
  ConsumerState<_NotificationsDialog> createState() =>
      _NotificationsDialogState();
}

class _NotificationsDialogState extends ConsumerState<_NotificationsDialog> {
  bool _includeRead = false;

  void _refresh() {
    ref.invalidate(myNotificationsProvider(_includeRead));
    ref.invalidate(unreadNotificationsProvider);
  }

  @override
  Widget build(BuildContext context) {
    final list = ref.watch(myNotificationsProvider(_includeRead));

    return AlertDialog(
      title: Row(children: [
        const Expanded(child: Text('Waiting for you')),
        // Read is not gone: somebody who cleared the bell in a hurry
        // still needs to find what it said.
        TextButton(
          onPressed: () => setState(() => _includeRead = !_includeRead),
          child: Text(_includeRead ? 'Unread only' : 'Show read'),
        ),
      ]),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: AsyncView(
            value: list,
            onRetry: _refresh,
            // An icon each for what kind of thing is waiting, which is
            // what `_NotificationTile` leads with.
            skeleton: const ListSkeleton(rows: 4, trailing: false),
            builder: (rows) => rows.isEmpty
                ? const Padding(
                    padding: EdgeInsets.symmetric(vertical: Space.md),
                    child: Text('Nothing is waiting for you.'),
                  )
                : Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final n in rows)
                        _NotificationTile(
                          entry: n,
                          onOpen: () async {
                            final route = n['route']?.toString();
                            await ref
                                .read(repoProvider)
                                ?.markNotificationRead('${n['id']}');
                            if (!context.mounted) return;
                            Navigator.pop(context);
                            if (route != null && route.isNotEmpty) {
                              context.go(route);
                            }
                          },
                          onDismiss: () async {
                            await ref
                                .read(repoProvider)
                                ?.dismissNotification('${n['id']}');
                            _refresh();
                          },
                        ),
                    ],
                  ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () async {
            await ref.read(repoProvider)?.markAllNotificationsRead();
            _refresh();
          },
          child: const Text('Mark all read'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
      ],
    );
  }
}

class _NotificationTile extends StatelessWidget {
  const _NotificationTile({
    required this.entry,
    required this.onOpen,
    required this.onDismiss,
  });

  final Map<String, dynamic> entry;
  final VoidCallback onOpen;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final severity = entry['severity']?.toString() ?? 'info';
    final unread = entry['read_at'] == null;
    final at = DateTime.tryParse(entry['created_at']?.toString() ?? '');

    final colour = switch (severity) {
      'urgent' => context.colors.danger,
      'warning' => context.colors.warning,
      _ => context.colors.info,
    };
    final icon = switch (entry['kind']?.toString()) {
      'einvoice_rejected' => Icons.gpp_bad_outlined,
      'ticket_overdue' => Icons.timer_off_outlined,
      'claim_to_approve' => Icons.rule_outlined,
      'fs_lodgement_due' => Icons.gavel_outlined,
      _ => Icons.info_outline,
    };

    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(icon, color: colour),
      title: Text(
        entry['title']?.toString() ?? '',
        style: TextStyle(
            fontWeight: unread ? FontWeight.w600 : FontWeight.w400),
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (entry['body'] != null &&
              '${entry['body']}'.trim().isNotEmpty)
            Text('${entry['body']}'),
          if (at != null)
            Text(Fmt.dateTime(at),
                style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
      trailing: IconButton(
        tooltip: 'Dismiss',
        icon: const Icon(Icons.close, size: 18),
        onPressed: onDismiss,
      ),
      onTap: onOpen,
    );
  }
}
