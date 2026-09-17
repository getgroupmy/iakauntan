import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/repository.dart';
import 'tax_details.dart';

/// Ask this contact for their own TIN, and decide about what comes
/// back.
///
/// 0626. Both halves are here rather than in two places because they
/// are one conversation: somebody sends the link on Monday, the
/// customer answers on Thursday, and the person who reads the answer is
/// the person looking at this contact.
///
/// The card says out loud what the public form can and cannot do. That
/// matters more here than on most cards: "we sent your customer a form
/// that writes into your contacts" is alarming until you know it only
/// fills blanks.
class TaxDetailsCard extends ConsumerStatefulWidget {
  const TaxDetailsCard({
    super.key,
    required this.contactId,
    required this.email,
  });

  final String contactId;
  final String? email;

  @override
  ConsumerState<TaxDetailsCard> createState() => _TaxDetailsCardState();
}

class _TaxDetailsCardState extends ConsumerState<TaxDetailsCard> {
  bool _busy = false;
  String? _justIssued;

  Future<void> _issue(TaxDetailLinkState current) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Ask them for their tax details?'),
        content: Text(
          taxDetailsIssuePrompt(
            replacing: current.live,
            sendingTo: widget.email,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Send it'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    setState(() => _busy = true);
    try {
      final out = await ref
          .read(repoProvider)!
          .requestTaxDetails(widget.contactId);
      if (!mounted) return;
      setState(() => _justIssued = out['url']?.toString());
      final to = out['sent_to']?.toString();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            (to == null || to.isEmpty)
                ? 'Link ready — copy it below and pass it on'
                : 'Sent to $to',
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    } finally {
      if (mounted) {
        setState(() => _busy = false);
        ref.invalidate(taxDetailLinksProvider(widget.contactId));
      }
    }
  }

  Future<void> _revoke() async {
    setState(() => _busy = true);
    try {
      await ref.read(repoProvider)!.revokeTaxDetailRequest(widget.contactId);
      if (!mounted) return;
      setState(() => _justIssued = null);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('The link no longer opens')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    } finally {
      if (mounted) {
        setState(() => _busy = false);
        ref.invalidate(taxDetailLinksProvider(widget.contactId));
      }
    }
  }

  Future<void> _decide(TaxSubmission s, {required bool accept}) async {
    setState(() => _busy = true);
    try {
      final repo = ref.read(repoProvider)!;
      if (accept) {
        await repo.applyTaxSubmission(s.id);
      } else {
        await repo.dismissTaxSubmission(s.id);
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            accept
                ? 'Taken. Reopen this contact to see the new values.'
                : 'Kept what you had.',
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    } finally {
      if (mounted) {
        setState(() => _busy = false);
        ref.invalidate(pendingTaxSubmissionsProvider);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final canWrite = ref.watch(canWriteProvider);
    final links = ref.watch(taxDetailLinksProvider(widget.contactId));
    final waiting = ref.watch(pendingTaxSubmissionsProvider);
    final text = Theme.of(context).textTheme;

    return Card(
      margin: const EdgeInsets.only(top: Space.lg),
      child: Padding(
        padding: const EdgeInsets.all(Space.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SectionHeader(
              'Ask them for their TIN',
              subtitle: 'A link they fill in themselves. It fills in what '
                  'is blank here and never overwrites what you already '
                  'hold — anything that disagrees waits for you below.',
            ),
            AsyncView(
              value: links,
              onRetry: () =>
                  ref.invalidate(taxDetailLinksProvider(widget.contactId)),
              loading: const LinearProgressIndicator(),
              builder: (rows) {
                final state = TaxDetailLinkState.fromRows(rows);
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      taxDetailsLinkStatusLine(state),
                      key: const ValueKey('tax-link-status'),
                      style: text.bodyMedium,
                    ),
                    if (_justIssued != null) ...[
                      const SizedBox(height: Space.md),
                      // Shown once, after issuing. The token is stored
                      // only as a hash, so this is the only moment the
                      // link exists in a form anybody can copy.
                      SelectableText(
                        _justIssued!,
                        key: const ValueKey('tax-link-url'),
                        style: text.bodySmall,
                      ),
                      TextButton.icon(
                        onPressed: () => Clipboard.setData(
                          ClipboardData(text: _justIssued!),
                        ),
                        icon: const Icon(Icons.copy, size: 16),
                        label: const Text('Copy link'),
                      ),
                    ],
                    const SizedBox(height: Space.md),
                    Wrap(
                      spacing: 8,
                      children: [
                        FilledButton.tonal(
                          key: const ValueKey('tax-link-issue'),
                          onPressed: !canWrite || _busy
                              ? null
                              : () => _issue(state),
                          child: Text(
                            state.live ? 'Send a new link' : 'Send a link',
                          ),
                        ),
                        if (state.live)
                          TextButton(
                            key: const ValueKey('tax-link-revoke'),
                            onPressed: !canWrite || _busy ? null : _revoke,
                            child: const Text('Stop the link working'),
                          ),
                      ],
                    ),
                  ],
                );
              },
            ),
            AsyncView(
              value: waiting,
              onRetry: () => ref.invalidate(pendingTaxSubmissionsProvider),
              loading: const SizedBox.shrink(),
              builder: (rows) {
                // Only this contact's. The function answers for the whole
                // company because a review screen will want that, and
                // filtering here is cheaper than a second function.
                final mine = [
                  for (final r in rows)
                    if (TaxSubmission.fromMap(r).contactId == widget.contactId)
                      TaxSubmission.fromMap(r),
                ];
                if (mine.isEmpty) return const SizedBox.shrink();
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const SizedBox(height: Space.lg),
                    const Divider(),
                    const SizedBox(height: Space.md),
                    Text(
                      'What they told you, that differs from this',
                      key: const ValueKey('tax-waiting-heading'),
                      style: text.titleSmall,
                    ),
                    for (final s in mine) _Waiting(
                      submission: s,
                      busy: _busy,
                      canWrite: canWrite,
                      onAccept: () => _decide(s, accept: true),
                      onDismiss: () => _decide(s, accept: false),
                    ),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _Waiting extends StatelessWidget {
  const _Waiting({
    required this.submission,
    required this.busy,
    required this.canWrite,
    required this.onAccept,
    required this.onDismiss,
  });

  final TaxSubmission submission;
  final bool busy;
  final bool canWrite;
  final VoidCallback onAccept;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final applied = taxAppliedNote(submission);
    return Padding(
      padding: const EdgeInsets.only(top: Space.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            taxSubmissionWho(submission),
            key: ValueKey('tax-waiting-who-${submission.id}'),
            style: text.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
          ),
          for (final c in submission.conflicts)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                taxConflictLine(c),
                key: ValueKey('tax-conflict-${submission.id}-${c.field}'),
                style: text.bodySmall,
              ),
            ),
          if (applied != null) ...[
            const SizedBox(height: 4),
            Text(
              applied,
              key: ValueKey('tax-applied-${submission.id}'),
              style: text.bodySmall?.copyWith(color: context.scheme.outline),
            ),
          ],
          const SizedBox(height: Space.sm),
          Wrap(
            spacing: 8,
            children: [
              FilledButton.tonal(
                key: ValueKey('tax-accept-${submission.id}'),
                onPressed: !canWrite || busy ? null : onAccept,
                child: const Text('Take what they said'),
              ),
              TextButton(
                key: ValueKey('tax-dismiss-${submission.id}'),
                onPressed: !canWrite || busy ? null : onDismiss,
                child: const Text('Keep what I have'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
