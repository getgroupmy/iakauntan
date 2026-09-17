import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../core/safe_link.dart';
import '../../data/reserved_names_repository.dart';
import 'attachments.dart';
import 'compose.dart';
import 'compose_dialog.dart';

/// Mail at this company's addresses on the platform's domain.
///
/// It was a list and a reader and nothing else, and said so: "this is
/// not a mail client... replying to a customer is what the invoice's
/// own send button is for". That held while the addresses were `sales@`
/// and `support@`. `0559` made an address a person's, and an address
/// with somebody's own name on it that cannot answer anybody is worse
/// than no address — the customer writes to `aisyah@`, Aisyah reads it
/// here and replies from Gmail, and the company's record of the
/// conversation is now half in one place and half in another.
///
/// So it answers. Still not a mail client: no folders, no HTML, no
/// forwarding, no search. A list, a reader, and a reply.
class InboxScreen extends ConsumerStatefulWidget {
  const InboxScreen({super.key});

  @override
  ConsumerState<InboxScreen> createState() => _InboxScreenState();
}

class _InboxScreenState extends ConsumerState<InboxScreen> {
  /// Null is everything that arrived, at every address. Choosing one
  /// shows that address's conversation instead — both directions,
  /// because what was said back is half of it.
  String? _mailboxId;

  /// What was searched for, once it was submitted.
  ///
  /// Submitted rather than typed. Every keystroke is a query against a
  /// full-text index over every body in the company, and the letter
  /// somebody is halfway through typing is not a search anybody asked
  /// for.
  String _query = '';

  final _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final boxes = ref.watch(myMailboxesProvider).valueOrNull ?? const [];
    final domain = ref.watch(mailDomainProvider).valueOrNull ?? 'iakauntan.com';
    final chosen = _mailboxId;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Inbox'),
        actions: [
          IconButton(
            tooltip: 'Check again',
            icon: const Icon(Icons.refresh),
            onPressed: _refresh,
          ),
        ],
      ),
      floatingActionButton: boxes.isEmpty
          ? null
          : FloatingActionButton.extended(
              onPressed: () async {
                await showCompose(context, ref, mailboxId: chosen);
                _refresh();
              },
              icon: const Icon(Icons.edit_outlined),
              label: const Text('Write'),
            ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              Space.md,
              Space.md,
              Space.md,
              0,
            ),
            child: TextField(
              controller: _search,
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                isDense: true,
                prefixIcon: const Icon(Icons.search, size: 20),
                hintText: 'Search this mail',
                suffixIcon: _query.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.close, size: 18),
                        tooltip: 'Clear',
                        onPressed: () {
                          _search.clear();
                          setState(() => _query = '');
                        },
                      ),
              ),
              onSubmitted: (v) => setState(() => _query = v.trim()),
            ),
          ),
          if (boxes.length > 1 || chosen != null)
            _Addresses(
              boxes: boxes,
              domain: domain,
              chosen: chosen,
              onChanged: (v) => setState(() => _mailboxId = v),
            ),
          Expanded(
            child: switch ((_query.isEmpty, chosen)) {
              (false, final m) => _Found(
                  search: (mailboxId: m, query: _query),
                  onReplied: _refresh,
                ),
              (true, null) => _Arrived(onReplied: _refresh),
              (true, final m) =>
                _Conversation(mailboxId: m!, onReplied: _refresh),
            },
          ),
        ],
      ),
    );
  }

  void _refresh() {
    ref.invalidate(inboxProvider);
    final chosen = _mailboxId;
    if (chosen != null) ref.invalidate(mailboxThreadProvider(chosen));
    if (_query.isNotEmpty) {
      ref.invalidate(
        mailSearchProvider((mailboxId: chosen, query: _query)),
      );
    }
  }
}

/// Which address is being looked at.
///
/// A row of chips rather than a dropdown: there are two or three of
/// them, they are the whole of the navigation this screen has, and one
/// of them is usually the person's own.
class _Addresses extends StatelessWidget {
  const _Addresses({
    required this.boxes,
    required this.domain,
    required this.chosen,
    required this.onChanged,
  });

  final List<Map<String, dynamic>> boxes;
  final String domain;
  final String? chosen;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(
        horizontal: Space.md,
        vertical: Space.sm,
      ),
      child: Row(
        children: [
          ChoiceChip(
            label: const Text('Everything that arrived'),
            selected: chosen == null,
            onSelected: (_) => onChanged(null),
          ),
          for (final b in boxes) ...[
            const SizedBox(width: Space.sm),
            ChoiceChip(
              label: Text(mailboxAddress(b, domain)),
              selected: chosen == '${b['id']}',
              onSelected: (_) => onChanged('${b['id']}'),
            ),
          ],
        ],
      ),
    );
  }
}

/// Everything that came in, at every address this company has.
class _Arrived extends ConsumerWidget {
  const _Arrived({required this.onReplied});

  final VoidCallback onReplied;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return AsyncView(
      value: ref.watch(inboxProvider),
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
          itemBuilder: (context, i) =>
              _Row(row: rows[i], onReplied: onReplied),
        );
      },
    );
  }
}

/// One address, both directions, newest first.
class _Conversation extends ConsumerWidget {
  const _Conversation({required this.mailboxId, required this.onReplied});

  final String mailboxId;
  final VoidCallback onReplied;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final thread = ref.watch(mailboxThreadProvider(mailboxId));
    return AsyncView(
      value: thread,
      onRetry: () => ref.invalidate(mailboxThreadProvider(mailboxId)),
      builder: (rows) {
        if (rows.isEmpty) {
          return const EmptyState(
            icon: Icons.mail_outline,
            title: 'Nothing here yet',
            message: 'Nothing has arrived at this address and nothing '
                'has been sent from it.',
          );
        }
        return ListView.separated(
          itemCount: rows.length,
          separatorBuilder: (_, __) => const Divider(height: 1),
          itemBuilder: (context, i) => _Row(
            row: rows[i],
            mailboxId: mailboxId,
            onReplied: onReplied,
          ),
        );
      },
    );
  }
}

/// What a search found.
///
/// The same rows as the two lists above, drawn by the same widget. What
/// is NOT here is any filtering: `search_mail` runs as whoever is
/// searching, so a colleague's message never reaches this screen to be
/// hidden by it.
class _Found extends ConsumerWidget {
  const _Found({required this.search, required this.onReplied});

  final MailSearch search;
  final VoidCallback onReplied;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return AsyncView(
      value: ref.watch(mailSearchProvider(search)),
      onRetry: () => ref.invalidate(mailSearchProvider(search)),
      builder: (rows) {
        if (rows.isEmpty) {
          return EmptyState(
            icon: Icons.search_off,
            title: 'Nothing matched',
            message: 'No message here says "${search.query}".',
          );
        }
        return ListView.separated(
          itemCount: rows.length,
          separatorBuilder: (_, __) => const Divider(height: 1),
          itemBuilder: (context, i) => _Row(
            row: rows[i],
            // A result carries its own mailbox, which is what a reply
            // has to leave from — the search spans all of them.
            mailboxId: rows[i]['mailbox_id'] as String?,
            onReplied: onReplied,
          ),
        );
      },
    );
  }
}

/// One line, whichever list it is in.
///
/// The two lists carry different column names for the same two facts —
/// `received_at` against `at`, a row that arrived against one that
/// left — so the reading is done here once rather than in each of them.
class _Row extends ConsumerWidget {
  const _Row({required this.row, required this.onReplied, this.mailboxId});

  final Map<String, dynamic> row;
  final String? mailboxId;
  final VoidCallback onReplied;

  bool get _outgoing => isOutgoing(row);

  DateTime? get _when =>
      DateTime.tryParse('${row['at'] ?? row['received_at']}');

  String get _subject => (row['subject'] as String?)?.isNotEmpty == true
      ? '${row['subject']}'
      : '(no subject)';

  String get _body => '${row['body_text'] ?? ''}';

  /// When it was read, for something that arrived.
  ///
  /// Two names for one fact: the everything-list selects the column
  /// itself, and `mailbox_thread` calls it `handled_at` because the
  /// same column in the other direction is when the message left.
  Object? get _readAt => row['read_at'] ?? row['handled_at'];

  /// Whose name goes on the line. For something that arrived it is who
  /// sent it; for something that left it is who it went to, because
  /// "from aisyah@" on every one of her own sent messages says nothing.
  String get _who {
    if (_outgoing) return '${row['to_email']}';
    return (row['from_name'] as String?)?.isNotEmpty == true
        ? '${row['from_name']}'
        : '${row['from_email']}';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final unread = !_outgoing && _readAt == null;
    final note = deliveryNote(row);

    return ListTile(
      leading: CircleAvatar(
        backgroundColor:
            unread ? scheme.primaryContainer : scheme.surfaceContainerHighest,
        child: _outgoing
            ? Icon(Icons.north_east, size: 16, color: scheme.onSurfaceVariant)
            : Text(
                Fmt.initials(_who),
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: unread
                      ? scheme.onPrimaryContainer
                      : scheme.onSurfaceVariant,
                ),
              ),
      ),
      title: Text(
        _subject,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontWeight: unread ? FontWeight.w700 : FontWeight.w500,
        ),
      ),
      subtitle: Text(
        _outgoing ? 'To $_who${note == null ? '' : ' · $note'}' : _who,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: row['status'] == 'failed'
              ? scheme.error
              : scheme.onSurfaceVariant,
        ),
      ),
      trailing: Text(
        Fmt.date(_when),
        style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
      ),
      onTap: () => _open(context, ref),
    );
  }

  Future<void> _open(BuildContext context, WidgetRef ref) async {
    // Marked read on opening rather than by a button, because opening it
    // is what reading it is. Failing to mark it is not worth telling
    // anybody about — the message is on the screen either way.
    if (!_outgoing && _readAt == null) {
      try {
        await ref
            .read(supabaseProvider)
            .from('inbound_emails')
            .update({'read_at': DateTime.now().toUtc().toIso8601String()})
            .eq('id', '${row['id']}');
        onReplied();
      } catch (_) {
        // Deliberately silent.
      }
    }
    if (!context.mounted) return;

    // A reply needs the mailbox it arrived at. The thread list is one
    // mailbox so it already knows; the everything-list carries it on
    // the row.
    final replyFrom = mailboxId ?? '${row['mailbox_id'] ?? ''}';
    final canReply = !_outgoing && replyFrom.isNotEmpty;

    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(_subject),
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
                  _body.trim().isNotEmpty
                      ? _body
                      : 'This message had no plain-text part.',
                ),
                if (!_outgoing) _Attachments(emailId: '${row['id']}'),
              ],
            ),
          ),
        ),
        actions: [
          if (canReply)
            TextButton(
              onPressed: () async {
                Navigator.pop(ctx);
                await showCompose(
                  context,
                  ref,
                  mailboxId: replyFrom,
                  to: '${row['from_email']}',
                  subject: replySubject(row['subject'] as String?),
                  body: quotedReply(
                    from: _who,
                    body: _body,
                    at: _when,
                  ),
                  inReplyTo: '${row['id']}',
                );
                onReplied();
              },
              child: const Text('Reply'),
            ),
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }
}

/// What came attached, and a way to open it.
///
/// Drawn only when there is something: a message with no attachments
/// shows no section at all rather than a line announcing an absence.
///
/// The link is signed and lasts an hour. The bucket is private and the
/// policy on it asks whether you work at the company whose mailbox this
/// arrived at — now, not when the message landed — so a permanent URL
/// would be a permanent answer to a question that keeps changing.
class _Attachments extends ConsumerWidget {
  const _Attachments({required this.emailId});

  final String emailId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rows = ref.watch(inboundAttachmentsProvider(emailId)).valueOrNull;
    final heading = attachmentsHeading(rows?.length ?? 0);
    if (rows == null || heading == null) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Divider(height: Space.xl),
        Text(
          heading,
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
        ),
        for (final a in rows)
          ListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            leading: const Icon(Icons.attach_file, size: 18),
            title: Text('${a['filename']}', style: const TextStyle(fontSize: 13)),
            subtitle: Text(
              attachmentLine(a),
              style: TextStyle(
                fontSize: 11,
                color: context.scheme.onSurfaceVariant,
              ),
            ),
            onTap: () async {
              try {
                final url = await inboundAttachmentUrl(
                  ref.read(supabaseProvider),
                  '${a['storage_path']}',
                );
                if (!context.mounted) return;
                final opened = await launchExternal(url);
                if (!context.mounted || opened) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Could not open that file.')),
                );
              } catch (e) {
                if (!context.mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('$e')),
                );
              }
            },
          ),
      ],
    );
  }
}
