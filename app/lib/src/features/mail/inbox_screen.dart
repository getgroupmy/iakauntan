import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/reserved_names_repository.dart';

/// Mail that arrived at this company's addresses on the platform's
/// domain.
///
/// A list and a reader, and nothing else. This is not a mail client:
/// there is no reply, no compose and no folders, because the thing
/// somebody actually needs from an address like `hello@iakauntan.com`
/// is to see what came in and act on it somewhere else in the app.
/// Replying to a customer is what the invoice's own send button is for.
class InboxScreen extends ConsumerWidget {
  const InboxScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mail = ref.watch(inboxProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Inbox'),
        actions: [
          IconButton(
            tooltip: 'Check again',
            icon: const Icon(Icons.refresh),
            onPressed: () => ref.invalidate(inboxProvider),
          ),
        ],
      ),
      body: AsyncView(
        value: mail,
        onRetry: () => ref.invalidate(inboxProvider),
        builder: (rows) {
          if (rows.isEmpty) {
            return const EmptyState(
              icon: Icons.mark_email_unread_outlined,
              title: 'Nothing has arrived yet',
              message: 'Mail sent to your addresses on our domain lands '
                  'here. Ask for an address in Settings.',
            );
          }
          return ListView.separated(
            itemCount: rows.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (context, i) => _Row(row: rows[i]),
          );
        },
      ),
    );
  }
}

class _Row extends ConsumerWidget {
  const _Row({required this.row});

  final Map<String, dynamic> row;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final unread = row['read_at'] == null;
    final sender = (row['from_name'] as String?)?.isNotEmpty == true
        ? '${row['from_name']}'
        : '${row['from_email']}';

    return ListTile(
      leading: CircleAvatar(
        backgroundColor:
            unread ? scheme.primaryContainer : scheme.surfaceContainerHighest,
        child: Text(
          Fmt.initials(sender),
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w700,
            color: unread ? scheme.onPrimaryContainer : scheme.onSurfaceVariant,
          ),
        ),
      ),
      title: Text(
        (row['subject'] as String?)?.isNotEmpty == true
            ? '${row['subject']}'
            : '(no subject)',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontWeight: unread ? FontWeight.w700 : FontWeight.w500,
        ),
      ),
      subtitle: Text(
        '$sender → ${row['to_email']}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: scheme.onSurfaceVariant),
      ),
      trailing: Text(
        Fmt.date(DateTime.tryParse('${row['received_at']}')),
        style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
      ),
      onTap: () => _open(context, ref),
    );
  }

  Future<void> _open(BuildContext context, WidgetRef ref) async {
    // Marked read on opening rather than by a button, because opening it
    // is what reading it is. Failing to mark it is not worth telling
    // anybody about — the message is on the screen either way.
    if (row['read_at'] == null) {
      final orgId = ref.read(currentOrgIdProvider);
      if (orgId != null) {
        try {
          await ref
              .read(supabaseProvider)
              .from('inbound_emails')
              .update({'read_at': DateTime.now().toUtc().toIso8601String()})
              .eq('id', '${row['id']}');
          ref.invalidate(inboxProvider);
        } catch (_) {
          // Deliberately silent.
        }
      }
    }
    if (!context.mounted) return;

    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          (row['subject'] as String?)?.isNotEmpty == true
              ? '${row['subject']}'
              : '(no subject)',
        ),
        content: SizedBox(
          width: 560,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'From ${row['from_email']}\nTo ${row['to_email']}',
                  style: TextStyle(
                    color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                  ),
                ),
                const Divider(height: Space.xl),
                // The plain-text part, deliberately. Rendering a
                // stranger's HTML is how a mail client becomes an attack
                // surface, and this one has no reason to be one.
                SelectableText(
                  (row['body_text'] as String?)?.trim().isNotEmpty == true
                      ? '${row['body_text']}'
                      : 'This message had no plain-text part.',
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }
}
