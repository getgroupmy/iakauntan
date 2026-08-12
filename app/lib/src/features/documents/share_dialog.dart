import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/repository.dart';

/// Giving a customer a way to see their own invoice.
///
/// Shows the history of links issued for this document as well as
/// issuing a new one, because "did they ever open it?" is the question
/// somebody asks a week later, and the answer is the only evidence the
/// link reached anybody.
Future<void> showShareDialog(
    BuildContext context, String documentId, String docNo) {
  return showDialog<void>(
    context: context,
    builder: (_) => _ShareDialog(documentId: documentId, docNo: docNo),
  );
}

class _ShareDialog extends ConsumerStatefulWidget {
  const _ShareDialog({required this.documentId, required this.docNo});

  final String documentId;
  final String docNo;

  @override
  ConsumerState<_ShareDialog> createState() => _ShareDialogState();
}

class _ShareDialogState extends ConsumerState<_ShareDialog> {
  final _email = TextEditingController();
  int _days = 30;
  bool _busy = false;

  @override
  void dispose() {
    _email.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final links = ref.watch(documentShareLinksProvider(widget.documentId));
    final live = (links.valueOrNull ?? const [])
        .where((l) => l['revoked_at'] == null)
        .toList();

    return AlertDialog(
      title: Text('Share ${widget.docNo}'),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Anybody holding the link can see this document — the '
                'lines, the totals and what is still owed. They cannot '
                'see your internal notes or what anything cost you, and '
                'the link works for this document only.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: Space.md),
              Row(children: [
                Expanded(
                  child: DropdownButtonFormField<int>(
                    value: _days,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: 'Expires in'),
                    items: const [
                      DropdownMenuItem(value: 7, child: Text('7 days')),
                      DropdownMenuItem(value: 30, child: Text('30 days')),
                      DropdownMenuItem(value: 90, child: Text('90 days')),
                      DropdownMenuItem(value: 365, child: Text('A year')),
                    ],
                    onChanged: (v) => setState(() => _days = v ?? 30),
                  ),
                ),
                const SizedBox(width: Space.md),
                Expanded(
                  flex: 2,
                  child: TextField(
                    controller: _email,
                    keyboardType: TextInputType.emailAddress,
                    decoration: const InputDecoration(
                      labelText: 'Who it is for',
                      helperText: 'Recorded against the link, not emailed',
                    ),
                  ),
                ),
              ]),
              const SizedBox(height: Space.md),
              Align(
                alignment: Alignment.centerLeft,
                child: FilledButton.icon(
                  onPressed: _busy ? null : _issue,
                  icon: const Icon(Icons.link, size: 18),
                  label: Text(live.isEmpty ? 'Create link' : 'Replace link'),
                ),
              ),
              if (live.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: Space.xs),
                  child: Text(
                    'Creating a new link stops the current one working.',
                    style: TextStyle(
                        fontSize: 12, color: context.colors.warning),
                  ),
                ),
              const Divider(height: Space.xl),
              AsyncView(
                value: links,
                onRetry: () =>
                    ref.invalidate(documentShareLinksProvider(widget.documentId)),
                builder: (list) => list.isEmpty
                    ? const Padding(
                        padding: EdgeInsets.symmetric(vertical: Space.md),
                        child: Text('This document has not been shared.'),
                      )
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [for (final l in list) _LinkTile(link: l)],
                      ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        if (live.isNotEmpty)
          TextButton(
            onPressed: _busy ? null : _revoke,
            child: Text('Revoke',
                style: TextStyle(color: context.colors.danger)),
          ),
        FilledButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Done'),
        ),
      ],
    );
  }

  Future<void> _issue() async {
    setState(() => _busy = true);
    String? token;
    final ok = await runWithFeedback(
      context,
      action: () async {
        token = await ref.read(repoProvider)!.shareDocument(
              widget.documentId,
              validDays: _days,
              email: _email.text,
            );
      },
      successMessage: 'Link created',
    );
    if (mounted) setState(() => _busy = false);
    ref.invalidate(documentShareLinksProvider(widget.documentId));
    if (!ok || token == null || !mounted) return;

    await showDialog<void>(
      context: context,
      builder: (_) => _TokenDialog(
        url: '${Uri.base.origin}/#/share/$token',
        docNo: widget.docNo,
      ),
    );
  }

  Future<void> _revoke() async {
    final ok = await confirm(
      context,
      title: 'Revoke the link?',
      message: 'Anybody holding it stops being able to open the document.',
      confirmLabel: 'Revoke',
      destructive: true,
    );
    if (!ok || !mounted) return;

    setState(() => _busy = true);
    await runWithFeedback(
      context,
      action: () => ref.read(repoProvider)!.revokeDocumentShare(widget.documentId),
      successMessage: 'Revoked',
    );
    if (mounted) setState(() => _busy = false);
    ref.invalidate(documentShareLinksProvider(widget.documentId));
  }
}

class _LinkTile extends StatelessWidget {
  const _LinkTile({required this.link});

  final Map<String, dynamic> link;

  @override
  Widget build(BuildContext context) {
    final revoked = link['revoked_at'] != null;
    final expires = Fmt.parseDate(link['expires_at']);
    final expired = expires != null && expires.isBefore(DateTime.now());
    final opens = Fmt.toInt(link['open_count']);
    final lastOpened = Fmt.parseDate(link['last_opened_at']);

    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      title: Row(children: [
        Flexible(
          child: Text(
            link['sent_to_email']?.toString() ?? 'No address recorded',
            overflow: TextOverflow.ellipsis,
          ),
        ),
        const SizedBox(width: Space.sm),
        StatusChip(
          revoked
              ? 'revoked'
              : expired
                  ? 'expired'
                  : 'active',
          compact: true,
        ),
      ]),
      subtitle: Text(
        [
          'issued ${Fmt.date(Fmt.parseDate(link['created_at']))}',
          if (expires != null)
            expired ? 'expired ${Fmt.date(expires)}' : 'until ${Fmt.date(expires)}',
          // The number people actually want.
          if (opens == 0)
            'never opened'
          else
            'opened $opens time${opens == 1 ? '' : 's'}'
                '${lastOpened == null ? '' : ', last ${Fmt.date(lastOpened)}'}',
        ].join(' · '),
        style: const TextStyle(fontSize: 12),
      ),
    );
  }
}

/// The one moment the link exists in readable form.
class _TokenDialog extends StatelessWidget {
  const _TokenDialog({required this.url, required this.docNo});

  final String url;
  final String docNo;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Link for $docNo'),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Copy it now. Only a fingerprint of the token is stored, so '
              'this cannot be shown again — closing this means issuing a '
              'new link.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: Space.md),
            SelectableText(
              url,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: url));
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Link copied')));
            }
          },
          child: const Text('Copy'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Done'),
        ),
      ],
    );
  }
}
