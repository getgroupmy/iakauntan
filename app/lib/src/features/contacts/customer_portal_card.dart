import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';

import '../../core/providers.dart';
import '../../core/skeletons.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/repository.dart';
import '../documents/customer_portal_summary.dart';

/// Give this customer a link to their own account.
///
/// 0067 shares one document at a time, from the document. This shares
/// the account, from the customer — and it belongs on the contact for
/// the same reason: the thing being disclosed is everything they owe,
/// which is a fact about the customer rather than about any one
/// invoice.
///
/// Only for a contact that can owe something. A supplier has no account
/// with us to look at.
class CustomerPortalCard extends ConsumerStatefulWidget {
  const CustomerPortalCard({
    super.key,
    required this.contactId,
    required this.contactType,
    required this.email,
  });

  final String contactId;
  final String contactType;
  final String? email;

  @override
  ConsumerState<CustomerPortalCard> createState() =>
      _CustomerPortalCardState();
}

class _CustomerPortalCardState extends ConsumerState<CustomerPortalCard> {
  bool _busy = false;
  String? _justIssued;

  bool get _appliesHere =>
      widget.contactType == 'customer' || widget.contactType == 'both';

  Future<void> _issue(PortalLinkState current) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Send them a link to their account?'),
        content: Text(portalIssuePrompt(
          replacing: current.live,
          sendingTo: widget.email,
        )),
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
          .shareCustomerPortal(widget.contactId);
      if (!mounted) return;
      setState(() => _justIssued = out['url']?.toString());
      final to = out['sent_to']?.toString();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            (to == null || to.isEmpty)
                // No address on file, so the link is the deliverable
                // rather than the delivery.
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
        ref.invalidate(customerPortalLinksProvider(widget.contactId));
      }
    }
  }

  Future<void> _revoke() async {
    setState(() => _busy = true);
    try {
      await ref.read(repoProvider)!.revokeCustomerPortal(widget.contactId);
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
        ref.invalidate(customerPortalLinksProvider(widget.contactId));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_appliesHere) return const SizedBox.shrink();
    final canWrite = ref.watch(canWriteProvider);
    final links = ref.watch(customerPortalLinksProvider(widget.contactId));
    final text = Theme.of(context).textTheme;

    return Card(
      margin: const EdgeInsets.only(top: Space.lg),
      child: Padding(
        padding: const EdgeInsets.all(Space.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SectionHeader(
              'Their account online',
              subtitle: 'One link showing everything they owe, and a way '
                  'to pay it. No sign-up for them.',
            ),
            AsyncView(
              value: links,
              onRetry: () => ref
                  .invalidate(customerPortalLinksProvider(widget.contactId)),
              // Two, because a contact usually has one live link and
              // perhaps one revoked.
              skeleton: const CardRowsSkeleton(
                rows: 2,
                leading: false,
                trailing: 1,
                rowGap: Space.xs,
              ),
              builder: (rows) {
                final state = PortalLinkState.fromRows(rows);
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      portalLinkStatusLine(state),
                      key: const ValueKey('portal-link-status'),
                      style: text.bodyMedium,
                    ),
                    if (_justIssued != null) ...[
                      const SizedBox(height: Space.md),
                      // Shown once, after issuing. The token is not
                      // stored anywhere it could be read back, so this
                      // is the only moment the link exists in a form
                      // anybody can copy.
                      SelectableText(
                        _justIssued!,
                        key: const ValueKey('portal-link-url'),
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
                          key: const ValueKey('portal-issue'),
                          onPressed: !canWrite || _busy
                              ? null
                              : () => _issue(state),
                          child: Text(
                            state.live ? 'Send a new link' : 'Send a link',
                          ),
                        ),
                        if (state.live)
                          TextButton(
                            key: const ValueKey('portal-revoke'),
                            onPressed: !canWrite || _busy ? null : _revoke,
                            child: const Text('Stop the link working'),
                          ),
                      ],
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
