import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/error_text.dart';
import '../../core/format.dart';
import '../../core/theme.dart';
import 'customer_portal_summary.dart';

/// A customer's whole account, on one link.
///
/// The sibling of [SharedDocumentPage] and, like it, works with no
/// account and does not use `repoProvider`: there may be no signed-in
/// user, and `open_customer_portal` authorises itself against the token
/// rather than against a JWT.
///
/// It renders no document. Tapping an invoice asks the server for a
/// normal document share token and goes to `/share/<token>`, which is
/// the page that already views and pays one — a directory, not a second
/// renderer, because a second renderer is a second place for the total
/// to be wrong.
class CustomerPortalPage extends StatefulWidget {
  const CustomerPortalPage({super.key, required this.token});

  final String token;

  @override
  State<CustomerPortalPage> createState() => _CustomerPortalPageState();
}

class _CustomerPortalPageState extends State<CustomerPortalPage> {
  late Future<PortalAccount> _account = _open();
  String? _busyId;

  Future<PortalAccount> _open() async {
    final data = await Supabase.instance.client
        .rpc('open_customer_portal', params: {'p_token': widget.token});
    return PortalAccount.fromMap(Map<String, dynamic>.from(data as Map));
  }

  Future<void> _openInvoice(PortalInvoice invoice) async {
    setState(() => _busyId = invoice.id);
    try {
      final token = await Supabase.instance.client.rpc(
        'portal_document_token',
        params: {'p_token': widget.token, 'p_document_id': invoice.id},
      );
      if (!mounted) return;
      context.go('/share/$token');
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(errorText(e))),
      );
    } finally {
      if (mounted) setState(() => _busyId = null);
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
            constraints: const BoxConstraints(maxWidth: 820),
            child: FutureBuilder<PortalAccount>(
              future: _account,
              builder: (context, snap) {
                if (snap.connectionState != ConnectionState.done) {
                  return const Padding(
                    padding: EdgeInsets.all(Space.xxl),
                    child: Center(child: CircularProgressIndicator()),
                  );
                }
                if (snap.hasError) {
                  return _PortalMessage(
                    icon: Icons.error_outline,
                    title: 'Something went wrong',
                    body: '${snap.error}',
                  );
                }
                final account = snap.data;
                if (account == null || !account.isOpen) {
                  final m = portalStateMessage(account?.state ?? 'invalid');
                  return _PortalMessage(
                    icon: switch (account?.state) {
                      'expired' => Icons.schedule,
                      'revoked' => Icons.link_off,
                      'withdrawn' => Icons.block,
                      _ => Icons.help_outline,
                    },
                    title: m.title,
                    body: m.body,
                  );
                }
                return _Account(
                  account: account,
                  busyId: _busyId,
                  onOpen: _openInvoice,
                  onRefresh: () => setState(() {
                    _account = _open();
                  }),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

class _Account extends StatelessWidget {
  const _Account({
    required this.account,
    required this.busyId,
    required this.onOpen,
    required this.onRefresh,
  });

  final PortalAccount account;
  final String? busyId;
  final Future<void> Function(PortalInvoice) onOpen;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Space.xl),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                if ((account.logoUrl ?? '').isNotEmpty) ...[
                  Image.network(
                    account.logoUrl!,
                    height: 40,
                    errorBuilder: (_, _, _) => const SizedBox.shrink(),
                  ),
                  const SizedBox(width: Space.md),
                ],
                Expanded(
                  child: Text(
                    account.companyName,
                    style: text.titleLarge
                        ?.copyWith(fontWeight: FontWeight.w600),
                  ),
                ),
                IconButton(
                  tooltip: 'Refresh',
                  icon: const Icon(Icons.refresh),
                  onPressed: onRefresh,
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(account.contactName, style: text.bodyMedium),
            const SizedBox(height: Space.lg),
            Text(
              portalOutstandingLine(account),
              key: const ValueKey('portal-outstanding'),
              style: text.headlineMedium
                  ?.copyWith(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 4),
            Text(portalSummaryLine(account), style: text.bodyMedium),
            if (!account.owesNothing) ...[
              const SizedBox(height: Space.lg),
              const Divider(),
              for (final i in account.invoices)
                ListTile(
                  key: ValueKey('portal-invoice-${i.id}'),
                  contentPadding: EdgeInsets.zero,
                  title: Text(portalInvoiceLine(i)),
                  subtitle: portalPartPaidNote(i) == null
                      ? null
                      : Text(portalPartPaidNote(i)!),
                  trailing: busyId == i.id
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              Fmt.money(i.balance, currency: account.currency),
                              style: text.titleMedium?.copyWith(
                                fontWeight: FontWeight.w600,
                                color: i.overdue
                                    ? context.scheme.error
                                    : null,
                              ),
                            ),
                            const SizedBox(width: 4),
                            const Icon(Icons.chevron_right),
                          ],
                        ),
                  onTap: busyId == null ? () => onOpen(i) : null,
                ),
            ],
            if ((account.companyEmail ?? '').isNotEmpty ||
                (account.companyPhone ?? '').isNotEmpty) ...[
              const SizedBox(height: Space.lg),
              // Somebody who thinks a figure here is wrong needs a way to
              // say so, and this page is the whole of their relationship
              // with the system.
              Text(
                'Questions about this account? '
                '${[account.companyEmail, account.companyPhone]
                        .where((s) => (s ?? '').isNotEmpty)
                        .join(' · ')}',
                style: text.bodySmall,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _PortalMessage extends StatelessWidget {
  const _PortalMessage({
    required this.icon,
    required this.title,
    required this.body,
  });

  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Space.xxl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 40, color: context.scheme.outline),
            const SizedBox(height: Space.md),
            Text(title, style: text.titleMedium),
            const SizedBox(height: 4),
            Text(
              body,
              style: text.bodySmall,
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
