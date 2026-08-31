import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/format.dart';
import '../../core/theme.dart';

/// What a customer sees when they are sent a link to their own ticket.
///
/// `ticket_comments.author_contact_id` has existed since `0192` with a
/// check constraint demanding exactly one author, and nothing ever wrote
/// it — so staff talked to each other on the ticket and the person who
/// raised it could not say anything at all. This is the other end.
///
/// Like the shared document page and the signing page it works with no
/// account and does not use `repoProvider`: there may be no signed-in
/// user, and `open_shared_ticket` authorises itself against the token
/// rather than against a JWT. What comes back is chosen in that function
/// and excludes every internal note, so there is nothing here to hide in
/// the presentation.
class SharedTicketPage extends ConsumerStatefulWidget {
  const SharedTicketPage({super.key, required this.token});

  final String token;

  @override
  ConsumerState<SharedTicketPage> createState() => _SharedTicketPageState();
}

class _SharedTicketPageState extends ConsumerState<SharedTicketPage> {
  late Future<Map<String, dynamic>> _ticket = _open();
  final _reply = TextEditingController();
  bool _sending = false;
  String? _error;

  Future<Map<String, dynamic>> _open() async {
    final data = await Supabase.instance.client
        .rpc('open_shared_ticket', params: {'p_token': widget.token});
    return Map<String, dynamic>.from(data as Map);
  }

  @override
  void dispose() {
    _reply.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final body = _reply.text.trim();
    if (body.isEmpty) return;
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      final data = await Supabase.instance.client.rpc(
        'reply_to_shared_ticket',
        params: {'p_token': widget.token, 'p_body': body},
      );
      final state = (data as Map)['state']?.toString() ?? 'invalid';
      if (state != 'open') {
        // The link stopped working between loading the page and
        // sending. Said plainly rather than swallowed: somebody who
        // types a paragraph and watches it vanish assumes it was sent.
        setState(() => _error = sharedTicketSentence(state));
      } else {
        _reply.clear();
        setState(() => _ticket = _open());
      }
    } catch (e) {
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.scheme.surfaceContainerLowest,
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(Space.xl),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: FutureBuilder<Map<String, dynamic>>(
              future: _ticket,
              builder: (context, snap) {
                if (snap.connectionState != ConnectionState.done) {
                  return const Padding(
                    padding: EdgeInsets.all(Space.xxl),
                    child: Center(child: CircularProgressIndicator()),
                  );
                }
                if (snap.hasError) {
                  return _TicketMessage(
                    icon: Icons.error_outline,
                    title: 'Something went wrong',
                    body: '${snap.error}',
                  );
                }
                final d = snap.data ?? const {'state': 'invalid'};
                final state = d['state']?.toString() ?? 'invalid';
                if (state != 'open') {
                  return _TicketMessage(
                    icon: Icons.link_off,
                    title: 'This link is not open',
                    body: sharedTicketSentence(state),
                  );
                }
                return _Conversation(
                  data: d,
                  controller: _reply,
                  sending: _sending,
                  error: _error,
                  onSend: _send,
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

/// What each state means to the person holding the link.
///
/// Deliberately not distinguishing a token that never existed from one
/// that was revoked in any way the reader could act on: telling them
/// apart tells somebody guessing tokens when they have found a real one.
String sharedTicketSentence(String state) => switch (state) {
      'expired' => 'The link has expired. Ask us for a new one and we '
          'will send it over.',
      'revoked' => 'The link has been replaced. Check for a more recent '
          'email from us, or ask us for a new one.',
      'withdrawn' => 'This request has been withdrawn.',
      'empty' => 'Write something first.',
      _ => 'We could not find this request. Check the link in the email, '
          'or reply to us and we will send it again.',
    };

/// Which side of the conversation a comment is on.
///
/// `mine` is all the server says about who wrote it, and that is
/// deliberate: a requester does not need the name of every agent who
/// touched the file, and giving it away is a habit that ends in giving
/// away more.
bool commentIsMine(Map<String, dynamic> comment) => comment['mine'] == true;

class _Conversation extends StatelessWidget {
  const _Conversation({
    required this.data,
    required this.controller,
    required this.sending,
    required this.error,
    required this.onSend,
  });

  final Map<String, dynamic> data;
  final TextEditingController controller;
  final bool sending;
  final String? error;
  final VoidCallback onSend;

  @override
  Widget build(BuildContext context) {
    final company = data['company'] as Map<String, dynamic>? ?? const {};
    final ticket = data['ticket'] as Map<String, dynamic>? ?? const {};
    final comments = (data['comments'] as List?) ?? const [];
    final note = ticket['resolution_note']?.toString();

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Space.xl),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(company['name']?.toString() ?? '',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: Space.lg),
            Row(children: [
              Expanded(
                child: Text(ticket['subject']?.toString() ?? '',
                    style: Theme.of(context).textTheme.headlineSmall),
              ),
              Chip(
                label: Text(Fmt.label(ticket['status']?.toString() ?? ''),
                    style: const TextStyle(fontSize: 11)),
                visualDensity: VisualDensity.compact,
              ),
            ]),
            Text(
              '${ticket['ticket_no'] ?? ''} · raised '
              '${Fmt.date(Fmt.parseDate(ticket['created_at']))}',
              style: TextStyle(
                  fontSize: 12, color: context.scheme.onSurfaceVariant),
            ),
            if ((ticket['description']?.toString() ?? '').isNotEmpty) ...[
              const SizedBox(height: Space.lg),
              Text(ticket['description'].toString()),
            ],
            if (note != null && note.isNotEmpty) ...[
              const SizedBox(height: Space.lg),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(Space.md),
                decoration: BoxDecoration(
                  color: context.scheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('What we did',
                        style: Theme.of(context).textTheme.labelMedium),
                    const SizedBox(height: Space.xs),
                    Text(note),
                  ],
                ),
              ),
            ],
            const SizedBox(height: Space.xl),
            const Divider(),
            const SizedBox(height: Space.md),
            if (comments.isEmpty)
              Text('Nothing has been added yet.',
                  style: TextStyle(color: context.scheme.onSurfaceVariant))
            else
              for (final c in comments)
                _CommentTile(
                  comment: Map<String, dynamic>.from(c as Map),
                  company: company['name']?.toString() ?? '',
                ),
            const SizedBox(height: Space.xl),
            TextField(
              key: const ValueKey('shared-ticket-reply'),
              controller: controller,
              enabled: !sending,
              minLines: 3,
              maxLines: 8,
              decoration: const InputDecoration(
                labelText: 'Reply',
                hintText: 'Anything else we should know?',
              ),
            ),
            if (error != null) ...[
              const SizedBox(height: Space.sm),
              Text(error!,
                  style:
                      TextStyle(fontSize: 12, color: context.colors.danger)),
            ],
            const SizedBox(height: Space.md),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton(
                key: const ValueKey('shared-ticket-send'),
                onPressed: sending ? null : onSend,
                child: sending
                    ? const SizedBox(
                        height: 16,
                        width: 16,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Text('Send'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CommentTile extends StatelessWidget {
  const _CommentTile({required this.comment, required this.company});

  final Map<String, dynamic> comment;
  final String company;

  @override
  Widget build(BuildContext context) {
    final mine = commentIsMine(comment);
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: Space.md),
        padding: const EdgeInsets.all(Space.md),
        constraints: const BoxConstraints(maxWidth: 520),
        decoration: BoxDecoration(
          color: mine
              ? context.scheme.primaryContainer
              : context.scheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(mine ? 'You' : company,
                style: Theme.of(context).textTheme.labelSmall),
            const SizedBox(height: Space.xs),
            Text(comment['body']?.toString() ?? ''),
            const SizedBox(height: Space.xs),
            Text(
              Fmt.date(Fmt.parseDate(comment['created_at'])),
              style: TextStyle(
                  fontSize: 11, color: context.scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}

class _TicketMessage extends StatelessWidget {
  const _TicketMessage({
    required this.icon,
    required this.title,
    required this.body,
  });

  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) => Card(
        child: Padding(
          padding: const EdgeInsets.all(Space.xxl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 40, color: context.scheme.onSurfaceVariant),
              const SizedBox(height: Space.lg),
              Text(title, style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: Space.sm),
              Text(body, textAlign: TextAlign.center),
            ],
          ),
        ),
      );
}
