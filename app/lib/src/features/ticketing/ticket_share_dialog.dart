import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/safe_link.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/repository.dart';

/// The link that lets the requester read and answer their own ticket.
///
/// `ticket_comments.author_contact_id` has existed since `0192` with a
/// check constraint demanding exactly one author, and nothing wrote it —
/// so the customer who raised the ticket could not say anything on it.
///
/// Shows the links already issued as well as issuing a new one, because
/// "did they ever open it?" is the question somebody asks a week later
/// and the open count is the only evidence the link reached anybody.

/// Whether the ticket can be shared at all, or null when it can.
///
/// `share_ticket` refuses these too, and its refusal is the one that
/// counts. Said here so the button can explain itself rather than
/// failing.
String? shareBlockedBecause(Map<String, dynamic> ticket) {
  if (ticket['requester_contact_id'] == null) {
    return 'This ticket was raised by a member of staff, who can already '
        'read it. A link is for a requester with no login.';
  }
  if (ticket['status'] == 'cancelled') {
    return 'A cancelled ticket is not shared.';
  }
  return null;
}

/// What a link row says about itself.
String describeTicketLink(Map<String, dynamic> link) {
  if (link['revoked_at'] != null) return 'Revoked';
  final expires = Fmt.parseDate(link['expires_at']);
  if (expires != null && expires.isBefore(DateTime.now())) {
    return 'Expired ${Fmt.date(expires)}';
  }
  final opens = (link['open_count'] as num?)?.toInt() ?? 0;
  final replies = (link['reply_count'] as num?)?.toInt() ?? 0;
  if (opens == 0) {
    return 'Not opened yet · expires ${Fmt.date(expires)}';
  }
  final parts = <String>[
    opens == 1 ? 'opened once' : 'opened $opens times',
    if (replies == 1) '1 reply' else if (replies > 1) '$replies replies',
  ];
  return '${parts.join(' · ')} · expires ${Fmt.date(expires)}';
}

Future<void> showTicketShareDialog(
  BuildContext context,
  Map<String, dynamic> ticket,
) =>
    showDialog<void>(
      context: context,
      builder: (_) => _TicketShareDialog(ticket: ticket),
    );

class _TicketShareDialog extends ConsumerStatefulWidget {
  const _TicketShareDialog({required this.ticket});

  final Map<String, dynamic> ticket;

  @override
  ConsumerState<_TicketShareDialog> createState() =>
      _TicketShareDialogState();
}

class _TicketShareDialogState extends ConsumerState<_TicketShareDialog> {
  final _email = TextEditingController();
  int _days = 30;
  bool _busy = false;

  String get _id => widget.ticket['id'] as String;

  @override
  void dispose() {
    _email.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final blocked = shareBlockedBecause(widget.ticket);
    final links = ref.watch(ticketShareLinksProvider(_id));

    return AlertDialog(
      title: Text('Share ${widget.ticket['ticket_no'] ?? 'ticket'}'),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (blocked != null)
                Text(blocked,
                    style: TextStyle(color: context.colors.warning))
              else ...[
                Text(
                  'The requester can read the conversation and reply on '
                  'it. Internal notes are never shown.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: Space.lg),
                Row(children: [
                  Expanded(
                    child: TextField(
                      key: const ValueKey('ticket-share-email'),
                      controller: _email,
                      enabled: !_busy,
                      decoration: const InputDecoration(
                        labelText: 'Sent to',
                        helperText: 'Recorded with the link, for later',
                      ),
                    ),
                  ),
                  const SizedBox(width: Space.md),
                  SizedBox(
                    width: 140,
                    child: DropdownButtonFormField<int>(
                      isExpanded: true,
                      initialValue: _days,
                      decoration: const InputDecoration(labelText: 'Valid'),
                      items: const [
                        DropdownMenuItem(value: 7, child: Text('7 days')),
                        DropdownMenuItem(value: 30, child: Text('30 days')),
                        DropdownMenuItem(value: 90, child: Text('90 days')),
                      ],
                      onChanged:
                          _busy ? null : (v) => setState(() => _days = v ?? 30),
                    ),
                  ),
                ]),
              ],
              const SizedBox(height: Space.lg),
              links.maybeWhen(
                data: (list) => list.isEmpty
                    ? const SizedBox.shrink()
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          for (final l in list)
                            ListTile(
                              dense: true,
                              leading: Icon(
                                l['revoked_at'] == null
                                    ? Icons.link
                                    : Icons.link_off,
                                size: 18,
                              ),
                              title: Text(describeTicketLink(l),
                                  style: const TextStyle(fontSize: 12)),
                              subtitle: l['sent_to_email'] == null
                                  ? null
                                  : Text('${l['sent_to_email']}',
                                      style: const TextStyle(fontSize: 11)),
                            ),
                        ],
                      ),
                orElse: () => const SizedBox.shrink(),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
        if (blocked == null) ...[
          TextButton(
            key: const ValueKey('ticket-share-revoke'),
            onPressed: _busy ? null : _revoke,
            child: const Text('Revoke'),
          ),
          FilledButton(
            key: const ValueKey('ticket-share-issue'),
            onPressed: _busy ? null : _issue,
            child: _busy
                ? const SizedBox(
                    height: 16,
                    width: 16,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('Create link'),
          ),
        ],
      ],
    );
  }

  Future<void> _issue() async {
    setState(() => _busy = true);
    String? token;
    final ok = await runWithFeedback(
      context,
      action: () async {
        token = await ref.read(repoProvider)!.shareTicket(
              _id,
              validDays: _days,
              email: _email.text,
            );
      },
      successMessage: 'Link created',
    );
    if (mounted) setState(() => _busy = false);
    ref.invalidate(ticketShareLinksProvider(_id));
    if (!ok || token == null || !mounted) return;

    // Shown once. The token is hashed on the way in and never stored in
    // the clear, so a link that is closed without being copied has to be
    // reissued rather than looked up.
    final url = '${shareOrigin()}/#/ticket/$token';
    await showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('The link'),
        content: SizedBox(
          width: 520,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SelectableText(url),
              const SizedBox(height: Space.md),
              Text(
                'Copy it now. It is stored hashed, so this is the only '
                'time it can be read.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Done'),
          ),
          Builder(
            builder: (dialogContext) => FilledButton(
              onPressed: () async {
                final nav = Navigator.of(dialogContext);
                await Clipboard.setData(ClipboardData(text: url));
                nav.pop();
              },
              child: const Text('Copy'),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _revoke() async {
    final ok = await confirm(
      context,
      title: 'Revoke the link?',
      message: 'Anybody holding it stops being able to read or reply to '
          'the ticket.',
      confirmLabel: 'Revoke',
      destructive: true,
    );
    if (!ok || !mounted) return;
    setState(() => _busy = true);
    await runWithFeedback(
      context,
      action: () => ref.read(repoProvider)!.revokeTicketShare(_id),
      successMessage: 'Revoked',
    );
    if (mounted) setState(() => _busy = false);
    ref.invalidate(ticketShareLinksProvider(_id));
  }
}
