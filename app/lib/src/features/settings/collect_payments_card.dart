import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/picker_options.dart';
import '../../core/providers.dart';
import '../../core/searchable_picker.dart';
import '../../data/repository.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../banking/new_bank_account_dialog.dart';

/// Letting a customer pay an invoice they were sent a link to.
///
/// This is the shop's own acquirer, not the platform's. `_WaysToPay` on
/// this same screen shows how the company pays *iAkauntan*; this is how
/// the company's customers pay *the company*, and the two have nothing
/// in common but the word gateway.
///
/// Nothing here ever displays a key. `org_payment_gateway_status`
/// answers with `has_api_key` and `has_signature_key`, and a key that
/// is set is shown as "set" — a screen that could redisplay it is a
/// screen that could leak it, and there is no reason to read one back.
/// Leaving the key box empty on a save keeps the stored one, which is
/// what makes correcting a collection id safe.
class CollectPaymentsCard extends ConsumerStatefulWidget {
  const CollectPaymentsCard({super.key});

  @override
  ConsumerState<CollectPaymentsCard> createState() =>
      _CollectPaymentsCardState();
}

class _CollectPaymentsCardState extends ConsumerState<CollectPaymentsCard> {
  // Billplz is the only acquirer wired to a checkout. The rest of
  // `payment_gateways` is registered and not implemented, and offering
  // a shop a form for one of those would be offering it a bill that
  // never appears.
  static const _gateway = 'billplz';

  String _mode = 'sandbox';
  final _key = TextEditingController();
  final _collection = TextEditingController();
  final _signature = TextEditingController();
  String? _bankAccountId;
  bool _active = false;
  bool _saving = false;
  String? _loadedFor;

  @override
  void dispose() {
    _key.dispose();
    _collection.dispose();
    _signature.dispose();
    super.dispose();
  }

  void _load(Map<String, dynamic>? row) {
    // The key boxes stay empty on purpose. There is nothing to put in
    // them: what is stored is never read back, and an empty box means
    // "leave it alone" on the next save.
    _key.clear();
    _signature.clear();
    _collection.text = row?['collection_ref']?.toString() ?? '';
    _active = row?['is_active'] == true;
  }

  Future<void> _save() async {
    final repo = ref.read(repoProvider);
    if (repo == null) return;
    setState(() => _saving = true);
    await runWithFeedback(
      context,
      action: () async {
        await repo.saveOrgPaymentGateway(
          gateway: _gateway,
          mode: _mode,
          apiKey: _key.text.trim().isEmpty ? null : _key.text.trim(),
          collectionRef: _collection.text.trim().isEmpty
              ? null
              : _collection.text.trim(),
          signatureKey:
              _signature.text.trim().isEmpty ? null : _signature.text.trim(),
          isActive: _active,
        );
        if (_bankAccountId != null) {
          await repo.saveOrgPaymentSettlement(
            gateway: _gateway,
            mode: _mode,
            bankAccountId: _bankAccountId,
          );
        }
      },
      successMessage: 'Saved',
    );
    if (mounted) {
      setState(() {
        _saving = false;
        _loadedFor = null;
      });
    }
    ref.invalidate(orgPaymentGatewaysProvider);
  }

  @override
  Widget build(BuildContext context) {
    final gateways = ref.watch(orgPaymentGatewaysProvider);
    final banks = ref.watch(bankAccountsProvider).valueOrNull ?? const [];

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Space.lg),
        child: AsyncView<List<Map<String, dynamic>>>(
          value: gateways,
          onRetry: () => ref.invalidate(orgPaymentGatewaysProvider),
          builder: (rows) {
            final row = rows
                .where((r) => r['gateway_code'] == _gateway && r['mode'] == _mode)
                .firstOrNull;
            if (_loadedFor != _mode) {
              _loadedFor = _mode;
              _load(row);
              _bankAccountId = null;
            }
            final ready = row != null &&
                row['has_api_key'] == true &&
                (row['collection_ref']?.toString() ?? '').isNotEmpty;

            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SectionHeader(
                  'Let customers pay online',
                  subtitle:
                      'Your own Billplz account, so a customer sent an '
                      'invoice link can pay it. The money lands in the '
                      'account you nominate and a receipt is raised '
                      'against the invoice when Billplz confirms.',
                ),
                const SizedBox(height: Space.md),
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(value: 'sandbox', label: Text('Sandbox')),
                    ButtonSegment(value: 'production', label: Text('Live')),
                  ],
                  selected: {_mode},
                  onSelectionChanged: (v) => setState(() {
                    _mode = v.first;
                    _loadedFor = null;
                  }),
                ),
                const SizedBox(height: Space.md),
                _Status(row: row),
                const SizedBox(height: Space.md),
                TextField(
                  controller: _key,
                  obscureText: true,
                  decoration: InputDecoration(
                    labelText: 'Secret key',
                    helperText: row?['has_api_key'] == true
                        ? 'One is stored. Leave this empty to keep it.'
                        : 'From Billplz → Settings → Account',
                  ),
                ),
                const SizedBox(height: Space.sm),
                TextField(
                  controller: _collection,
                  decoration: const InputDecoration(
                    labelText: 'Collection id',
                    helperText: 'Which Billplz collection the bills go into',
                  ),
                ),
                const SizedBox(height: Space.sm),
                TextField(
                  controller: _signature,
                  obscureText: true,
                  decoration: InputDecoration(
                    labelText: 'X Signature key',
                    helperText: row?['has_signature_key'] == true
                        ? 'One is stored. Leave this empty to keep it.'
                        : 'Without it a payment confirmation cannot be '
                            'trusted, so none will be accepted',
                  ),
                ),
                const SizedBox(height: Space.md),
                SearchablePicker<String>(
                  options: bankPickerOptions(banks),
                  createLabel: 'Add bank account',
                  // 0529 made this list writable for the first
                  // time. Until then a company that opened a
                  // second account had nowhere in the product to
                  // say so.
                  onCreate: (typed) =>
                      createBankAccountFromPicker(context, typed: typed),
                  value: _bankAccountId,
                  label: 'Takings land in',
                  helperText: 'Required before customers are offered this '
                      'way of paying',
                  onChanged: (v) => setState(() => _bankAccountId = v),
                ),
                const SizedBox(height: Space.md),
                SwitchListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  value: _active,
                  onChanged: (v) => setState(() => _active = v),
                  title: const Text('Offer this to customers'),
                  subtitle: Text(
                    ready
                        ? 'A Pay button appears on every invoice link with '
                            'something still owing'
                        : 'Nothing is offered until a key and a collection '
                            'are stored and an account is nominated',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
                const SizedBox(height: Space.md),
                Align(
                  alignment: Alignment.centerLeft,
                  child: FilledButton(
                    onPressed: _saving ? null : _save,
                    child: const Text('Save'),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// What is stored, said without saying what it is.
class _Status extends StatelessWidget {
  const _Status({required this.row});

  final Map<String, dynamic>? row;

  @override
  Widget build(BuildContext context) {
    if (row == null) {
      return Text(
        'Nothing set up for this mode yet.',
        style: Theme.of(context).textTheme.bodySmall,
      );
    }
    final bits = <String>[
      row!['has_api_key'] == true ? 'Key stored' : 'No key',
      row!['has_signature_key'] == true
          ? 'Signature key stored'
          : 'No signature key',
      row!['is_active'] == true ? 'Offered to customers' : 'Not offered',
    ];
    return Text(
      bits.join(' · '),
      style: Theme.of(context)
          .textTheme
          .bodySmall
          ?.copyWith(color: context.scheme.onSurfaceVariant),
    );
  }
}
