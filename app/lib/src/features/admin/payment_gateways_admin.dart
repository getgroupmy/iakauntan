import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/platform_catalog_repository.dart';

/// How a company settles a platform invoice.
///
/// `platform_invoices` has billed companies for their modules since
/// 0018 and `platform_mark_invoice_paid` has settled one by hand ever
/// since. What was missing is the company paying it themselves.
///
/// ## What is not on this screen
///
/// The secret key. The field below is the *name* of an Edge Function
/// secret, not a secret — `payment_gateways` is readable by every
/// signed-in user so that a company can be shown the ways it may pay,
/// and anything confidential in it would be confidential handed to
/// every tenant. 0292 refuses a value that looks like a pasted key
/// rather than a name, and `supabase/tests/platform_pricing_and_payment.sql`
/// asserts that no column here is a place to put one.
///
/// Set the secret itself in Supabase → Edge Functions → Secrets, under
/// the name given here.
class PaymentGatewaysAdminTab extends ConsumerWidget {
  const PaymentGatewaysAdminTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final gateways = ref.watch(platformGatewaysAdminProvider);
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _edit(context, ref, null),
        icon: const Icon(Icons.add),
        label: const Text('Add a gateway'),
      ),
      body: AsyncView<List<Map<String, dynamic>>>(
        value: gateways,
        onRetry: () => ref.invalidate(platformGatewaysAdminProvider),
        builder: (rows) {
          if (rows.isEmpty) {
            return const EmptyState(
              icon: Icons.credit_card_outlined,
              title: 'No way to pay online',
              message:
                  'Platform invoices are settled by hand until a gateway is '
                  'added here.',
            );
          }
          return ListView(
            padding: const EdgeInsets.only(bottom: 96),
            children: [
              for (final r in rows)
                ListTile(
                  title: Row(
                    children: [
                      Flexible(child: Text('${r['name']}')),
                      const SizedBox(width: Space.sm),
                      StatusChip('${r['mode']}', compact: true),
                      if (r['is_active'] != true) ...[
                        const SizedBox(width: Space.sm),
                        const StatusChip('off', compact: true),
                      ],
                    ],
                  ),
                  subtitle: Text(
                    [
                      '${r['code']}',
                      '${r['currency']}',
                      // Where it sells, because 0295 seeds forty-odd
                      // providers and a list of names alone is a list
                      // nobody can find anything in.
                      if (r['countries'] is List &&
                          (r['countries'] as List).isNotEmpty)
                        (r['countries'] as List).join(', '),
                      if (r['secret_ref'] != null)
                        'secret in ${r['secret_ref']}'
                      else
                        'not configured',
                    ].join(' · '),
                    style: const TextStyle(fontSize: 12),
                  ),
                  onTap: () => _edit(context, ref, r),
                ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _edit(
    BuildContext context,
    WidgetRef ref,
    Map<String, dynamic>? existing,
  ) async {
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => _GatewayDialog(existing: existing),
    );
    if (saved == true) ref.invalidate(platformGatewaysAdminProvider);
  }
}

class _GatewayDialog extends ConsumerStatefulWidget {
  const _GatewayDialog({required this.existing});

  final Map<String, dynamic>? existing;

  @override
  ConsumerState<_GatewayDialog> createState() => _GatewayDialogState();
}

class _GatewayDialogState extends ConsumerState<_GatewayDialog> {
  late final _code = TextEditingController(
    text: '${widget.existing?['code'] ?? ''}',
  );
  late final _name = TextEditingController(
    text: '${widget.existing?['name'] ?? ''}',
  );
  late final _currency = TextEditingController(
    text: '${widget.existing?['currency'] ?? 'MYR'}',
  );
  late final _publishable = TextEditingController(
    text: '${widget.existing?['publishable_key'] ?? ''}',
  );
  late final _secretRef = TextEditingController(
    text: '${widget.existing?['secret_ref'] ?? ''}',
  );
  late final _checkout = TextEditingController(
    text: '${widget.existing?['checkout_url'] ?? ''}',
  );
  late final _instructions = TextEditingController(
    text: '${widget.existing?['instructions'] ?? ''}',
  );
  late String _mode = '${widget.existing?['mode'] ?? 'sandbox'}';
  late bool _active = widget.existing?['is_active'] == true;
  bool _busy = false;

  @override
  void dispose() {
    for (final c in [
      _code,
      _name,
      _currency,
      _publishable,
      _secretRef,
      _checkout,
      _instructions,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  String? _changed(TextEditingController c, String key) {
    final now = c.text.trim();
    final before = '${widget.existing?[key] ?? ''}'.trim();
    return now == before ? null : now;
  }

  Future<void> _save() async {
    final code = _code.text.trim();
    if (code.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('A gateway needs a code.')));
      return;
    }
    setState(() => _busy = true);
    final ok = await runWithFeedback(
      context,
      successMessage: 'Gateway saved',
      action: () => ref.read(platformCatalogProvider).savePaymentGateway(
        code,
        name: _changed(_name, 'name'),
        mode: _mode != '${widget.existing?['mode'] ?? 'sandbox'}' ? _mode : null,
        currency: _changed(_currency, 'currency'),
        publishableKey: _changed(_publishable, 'publishable_key'),
        secretRef: _changed(_secretRef, 'secret_ref'),
        checkoutUrl: _changed(_checkout, 'checkout_url'),
        instructions: _changed(_instructions, 'instructions'),
        isActive: _active != (widget.existing?['is_active'] == true)
            ? _active
            : (widget.existing == null ? _active : null),
      ),
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final isNew = widget.existing == null;
    return AlertDialog(
      title: Text(isNew ? 'Add a gateway' : '${widget.existing!['code']}'),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: _code,
                enabled: isNew,
                decoration: const InputDecoration(
                  labelText: 'Code',
                  helperText: 'billplz, toyyibpay, ipay88, stripe',
                ),
              ),
              const SizedBox(height: Space.sm),
              TextField(
                controller: _name,
                decoration: const InputDecoration(
                  labelText: 'Name',
                  helperText: 'What a company sees on the pay button',
                ),
              ),
              const SizedBox(height: Space.sm),
              DropdownButtonFormField<String>(
                value: _mode,
                decoration: const InputDecoration(
                  labelText: 'Mode',
                  helperText: 'Sandbox until a real payment has gone through',
                ),
                items: const [
                  DropdownMenuItem(value: 'sandbox', child: Text('sandbox')),
                  DropdownMenuItem(value: 'live', child: Text('live')),
                ],
                onChanged: (v) => setState(() => _mode = v ?? 'sandbox'),
              ),
              const SizedBox(height: Space.sm),
              TextField(
                controller: _currency,
                decoration: const InputDecoration(labelText: 'Currency'),
              ),
              const SizedBox(height: Space.sm),
              TextField(
                controller: _publishable,
                decoration: const InputDecoration(
                  labelText: 'Publishable key',
                  helperText: 'Safe to send to a browser. That is what it is '
                      'for.',
                ),
              ),
              const SizedBox(height: Space.sm),
              TextField(
                controller: _secretRef,
                decoration: const InputDecoration(
                  labelText: 'Secret name',
                  helperText: 'The NAME of an Edge Function secret, like '
                      'BILLPLZ_SECRET_KEY. Not the key itself — this table '
                      'is readable by every company.',
                ),
              ),
              const SizedBox(height: Space.sm),
              TextField(
                controller: _checkout,
                decoration: const InputDecoration(
                  labelText: 'Checkout address',
                  helperText: 'https only',
                ),
              ),
              const SizedBox(height: Space.sm),
              TextField(
                controller: _instructions,
                maxLines: 2,
                decoration: const InputDecoration(
                  labelText: 'What to tell the payer',
                ),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: _active,
                onChanged: (v) => setState(() => _active = v),
                title: const Text('Offer it to companies'),
                subtitle: const Text(
                  'Off while it is being set up. Companies are shown only '
                  'the ones switched on.',
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _busy ? null : _save,
          child: const Text('Save'),
        ),
      ],
    );
  }
}
