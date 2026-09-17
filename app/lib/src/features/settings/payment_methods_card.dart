import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../core/searchable_picker.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/models.dart';
import '../../data/repository.dart';
import 'payment_methods.dart';

/// The ways a company takes and sends money, and what each one costs.
///
/// `0635`. Distinct from LHDN's payment modes, which are a statutory
/// list of eight and not a company's data. A method points at one of
/// those and adds the two things the ledger cares about: which bank
/// account it lands in, and where the provider's cut is posted.
///
/// The cut is recorded, not applied. A screen that offers "2.9% + RM1"
/// and then posts whatever the receipt says is only honest if it says
/// so where the rate is entered, which is what [chargeRateNote] is for.
class PaymentMethodsCard extends ConsumerWidget {
  const PaymentMethodsCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final methods = ref.watch(paymentMethodsProvider);
    final canEdit = ref.watch(canWriteProvider);

    Future<void> edit([PaymentMethod? existing]) async {
      final saved = await showDialog<bool>(
        context: context,
        builder: (_) => PaymentMethodDialog(existing: existing),
      );
      if (saved == true) ref.invalidate(paymentMethodsProvider);
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Space.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SectionHeader(
              'Payment methods',
              subtitle:
                  'How money arrives and leaves, and where each '
                  'method\'s bank charge is posted',
              action: canEdit
                  ? TextButton.icon(
                      key: const ValueKey('add-payment-method'),
                      onPressed: () => edit(),
                      icon: const Icon(Icons.add, size: 18),
                      label: const Text('Add'),
                    )
                  : null,
            ),
            AsyncView(
              value: methods,
              onRetry: () => ref.invalidate(paymentMethodsProvider),
              loading: const LinearProgressIndicator(),
              builder: (list) => list.isEmpty
                  ? const Padding(
                      padding: EdgeInsets.symmetric(vertical: 8),
                      child: Text(
                        noPaymentMethodsLine,
                        style: TextStyle(fontSize: 13),
                      ),
                    )
                  : Column(
                      children: [
                        for (final m in list)
                          _MethodTile(
                            method: m,
                            onTap: canEdit ? () => edit(m) : null,
                          ),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MethodTile extends StatelessWidget {
  const _MethodTile({required this.method, this.onTap});

  final PaymentMethod method;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).textTheme.bodySmall
        ?.copyWith(color: context.scheme.onSurfaceVariant);

    return InkWell(
      key: ValueKey('payment-method-${method.id}'),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    method.name,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${paymentModeLabel(method.paymentModeCode)} · '
                    '${chargeSummary(method)}',
                    style: muted,
                  ),
                  Text(chargeAccountLine(method), style: muted),
                ],
              ),
            ),
            if (method.isDefault)
              const Padding(
                padding: EdgeInsets.only(right: 8),
                child: StatusChip('default', compact: true),
              ),
            if (!method.isActive)
              const Padding(
                padding: EdgeInsets.only(right: 8),
                child: StatusChip('inactive', compact: true),
              ),
            if (onTap != null) const Icon(Icons.chevron_right, size: 18),
          ],
        ),
      ),
    );
  }
}

/// Public so a widget test can pump it without a Supabase client.
class PaymentMethodDialog extends ConsumerStatefulWidget {
  const PaymentMethodDialog({super.key, this.existing});

  final PaymentMethod? existing;

  @override
  ConsumerState<PaymentMethodDialog> createState() =>
      PaymentMethodDialogState();
}

class PaymentMethodDialogState extends ConsumerState<PaymentMethodDialog> {
  late final TextEditingController _name = TextEditingController(
    text: widget.existing?.name ?? '',
  );
  late final TextEditingController _percent = TextEditingController(
    text: (widget.existing?.chargePercent ?? 0) == 0
        ? ''
        : '${widget.existing!.chargePercent}',
  );
  late final TextEditingController _fixed = TextEditingController(
    text: (widget.existing?.chargeFixed ?? 0) == 0
        ? ''
        : '${widget.existing!.chargeFixed}',
  );

  late String? _mode = widget.existing?.paymentModeCode;
  late String? _bankAccountId = widget.existing?.bankAccountId;
  late String? _chargeAccountId = widget.existing?.chargeAccountId;
  late bool _isDefault = widget.existing?.isDefault ?? false;
  late bool _isActive = widget.existing?.isActive ?? true;

  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _percent.dispose();
    _fixed.dispose();
    super.dispose();
  }

  double get _pct => double.tryParse(_percent.text.trim()) ?? 0;
  double get _fix => double.tryParse(_fixed.text.trim()) ?? 0;

  Future<void> _save() async {
    final problem = paymentMethodProblem(
      name: _name.text,
      chargePercent: _pct,
      chargeFixed: _fix,
    );
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref
          .read(repoProvider)!
          .savePaymentMethod(
            id: widget.existing?.id,
            name: _name.text.trim(),
            paymentModeCode: _mode,
            bankAccountId: _bankAccountId,
            chargeAccountId: _chargeAccountId,
            chargePercent: _pct,
            chargeFixed: _fix,
            isDefault: _isDefault,
            isActive: _isActive,
            sortOrder: widget.existing?.sortOrder ?? 0,
          );
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = e.toString();
        });
      }
    }
  }

  Future<void> _archive() async {
    final id = widget.existing?.id;
    if (id == null) return;
    setState(() => _busy = true);
    try {
      await ref.read(repoProvider)!.archivePaymentMethod(id);
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = e.toString();
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final accounts = ref.watch(accountsProvider).valueOrNull ?? const [];
    final banks = ref.watch(bankAccountsProvider).valueOrNull ?? const [];
    final muted = Theme.of(context).textTheme.bodySmall
        ?.copyWith(color: context.scheme.onSurfaceVariant);

    return AlertDialog(
      title: Text(
        widget.existing == null ? 'Add payment method' : 'Payment method',
      ),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                key: const ValueKey('payment-method-name'),
                controller: _name,
                decoration: const InputDecoration(
                  labelText: 'Name',
                  hintText: 'Maybank cheque, Stripe, cash at the counter',
                ),
              ),
              const SizedBox(height: Space.md),
              DropdownButtonFormField<String?>(
                key: const ValueKey('payment-method-mode'),
                value: _mode,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: 'Reports on an e-Invoice as',
                ),
                items: [
                  const DropdownMenuItem(
                    value: null,
                    child: Text('Not set for e-Invoice'),
                  ),
                  for (final e in paymentModeNames.entries)
                    DropdownMenuItem(value: e.key, child: Text(e.value)),
                ],
                onChanged: (v) => setState(() => _mode = v),
              ),
              const SizedBox(height: Space.md),
              SearchablePicker<String>(
                key: const ValueKey('payment-method-bank'),
                label: 'Money lands in',
                value: _bankAccountId,
                allowEmpty: true,
                emptyLabel: 'Chosen on the document',
                options: [
                  for (final b in banks)
                    PickerOption(
                      value: b['id']?.toString() ?? '',
                      label: b['name']?.toString() ?? '',
                      sublabel: b['account_no']?.toString(),
                    ),
                ],
                onChanged: (v) => setState(() => _bankAccountId = v),
              ),
              const SizedBox(height: Space.md),
              SearchablePicker<String>(
                key: const ValueKey('payment-method-charge-account'),
                label: 'Bank charges post to',
                value: _chargeAccountId,
                allowEmpty: true,
                // Not "None". Leaving this alone is a decision with a
                // meaning, and the meaning is the company's account.
                emptyLabel: 'The company account',
                options: [
                  for (final a in accounts.where(
                    (a) => a.accountType == 'expense' && !a.isGroup,
                  ))
                    PickerOption(
                      value: a.id,
                      label: '${a.code} ${a.name}',
                      keywords: [a.code, a.name],
                    ),
                ],
                onChanged: (v) => setState(() => _chargeAccountId = v),
              ),
              const SizedBox(height: Space.lg),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      key: const ValueKey('payment-method-percent'),
                      controller: _percent,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      decoration: const InputDecoration(
                        labelText: 'Charge %',
                        hintText: '2.9',
                      ),
                    ),
                  ),
                  const SizedBox(width: Space.md),
                  Expanded(
                    child: TextField(
                      key: const ValueKey('payment-method-fixed'),
                      controller: _fixed,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      decoration: const InputDecoration(
                        labelText: 'Charge fixed',
                        hintText: '1.00',
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: Space.sm),
              Text(chargeRateNote, style: muted),
              const SizedBox(height: Space.md),
              CheckboxListTile(
                key: const ValueKey('payment-method-default'),
                contentPadding: EdgeInsets.zero,
                value: _isDefault,
                title: const Text('Use this one by default'),
                onChanged: (v) => setState(() => _isDefault = v ?? false),
              ),
              CheckboxListTile(
                key: const ValueKey('payment-method-active'),
                contentPadding: EdgeInsets.zero,
                value: _isActive,
                title: const Text('Offer it on new documents'),
                onChanged: (v) => setState(() => _isActive = v ?? true),
              ),
              if (_error != null) ...[
                const SizedBox(height: Space.sm),
                Text(
                  _error!,
                  style: TextStyle(color: context.colors.danger, fontSize: 12),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        if (widget.existing != null)
          TextButton(
            key: const ValueKey('payment-method-archive'),
            onPressed: _busy ? null : _archive,
            child: const Text('Retire'),
          ),
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('payment-method-save'),
          onPressed: _busy ? null : _save,
          child: const Text('Save'),
        ),
      ],
    );
  }
}
