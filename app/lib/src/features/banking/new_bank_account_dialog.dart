import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';

/// Add a bank account without leaving what you were recording.
///
/// This is the one the sweep found by its absence. `bank_accounts` has
/// been readable from the app since the beginning and was never once
/// writable from it: every screen that reaches for an account — the
/// reconciliation, the expense, the receipt, the payment, the disposal,
/// the claim, the transfer — offered whatever the bootstrap happened to
/// insert, and a company that opened a second account had no way to say
/// so anywhere in the product.
///
/// WHAT IT ASKS FOR is a name, and then the three things that are only
/// worth having if they are right: the bank, the account number, and
/// the currency. `upsert_bank_account` makes the GL account behind it
/// and numbers it, because that is the half a person cannot be expected
/// to get right and the half that decides where the money appears on
/// the balance sheet.
class NewBankAccountDialog extends ConsumerStatefulWidget {
  const NewBankAccountDialog({super.key, this.seedName});

  /// What was typed into the picker.
  final String? seedName;

  @override
  ConsumerState<NewBankAccountDialog> createState() =>
      _NewBankAccountDialogState();
}

/// What a bank account can be. The four `bank_accounts.account_type`
/// takes, in the words a bank statement uses.
const bankAccountTypes = <String, String>{
  'current': 'Current',
  'savings': 'Savings',
  'fixed_deposit': 'Fixed deposit',
  'credit_card': 'Credit card',
};

class _NewBankAccountDialogState
    extends ConsumerState<NewBankAccountDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _name;
  final _bank = TextEditingController();
  final _number = TextEditingController();
  final _currency = TextEditingController(text: 'MYR');
  String _type = 'current';
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.seedName ?? '');
  }

  @override
  void dispose() {
    _name.dispose();
    _bank.dispose();
    _number.dispose();
    _currency.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('New bank account'),
      content: SizedBox(
        width: 460,
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Not on file yet. Fill this in and it will be used. An '
                'account on the chart is opened for it automatically, in '
                'the bank range.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _name,
                autofocus: widget.seedName == null,
                decoration: const InputDecoration(
                  labelText: 'Name',
                  hintText: 'Maybank current account',
                  helperText: 'What it is called on screen and on the '
                      'balance sheet.',
                ),
                validator: (v) =>
                    (v ?? '').trim().isEmpty ? 'It needs a name.' : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _bank,
                autofocus: widget.seedName != null,
                decoration: const InputDecoration(
                  labelText: 'Bank',
                  hintText: 'Malayan Banking Berhad',
                ),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _number,
                decoration: const InputDecoration(
                  labelText: 'Account number',
                  // Said here rather than when a payment file is
                  // rejected by the bank for having no account to pay
                  // from.
                  helperText: 'Needed before a payment file can name it.',
                ),
                keyboardType: TextInputType.number,
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    flex: 2,
                    child: DropdownButtonFormField<String>(
                      isExpanded: true,
                      value: _type,
                      decoration: const InputDecoration(labelText: 'Kind'),
                      items: [
                        for (final entry in bankAccountTypes.entries)
                          DropdownMenuItem(
                            value: entry.key,
                            child: Text(entry.value),
                          ),
                      ],
                      onChanged: (v) =>
                          setState(() => _type = v ?? 'current'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextFormField(
                      controller: _currency,
                      decoration: const InputDecoration(
                        labelText: 'Currency',
                      ),
                      textCapitalization: TextCapitalization.characters,
                      validator: (v) =>
                          (v ?? '').trim().length == 3 ? null : 'Three letters',
                    ),
                  ),
                ],
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(
                  _error!,
                  style:
                      TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: const Text('Create and use'),
        ),
      ],
    );
  }

  String? _blank(TextEditingController c) =>
      c.text.trim().isEmpty ? null : c.text.trim();

  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final repo = ref.read(repoProvider);
    if (repo == null) return;

    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final id = await repo.upsertBankAccount(
        name: _name.text.trim(),
        bankName: _blank(_bank),
        accountNumber: _blank(_number),
        accountType: _type,
        currency: _currency.text.trim().toUpperCase(),
      );
      // Every bank picker reads this, and the chart gained an account,
      // so both lists are re-read.
      ref.invalidate(bankAccountsProvider);
      ref.invalidate(accountsProvider);
      if (mounted) Navigator.pop(context, id);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }
}

/// Add a bank account from the box that wanted one, and return its id.
Future<String?> createBankAccountFromPicker(
  BuildContext context, {
  required String typed,
}) => showDialog<String>(
  context: context,
  builder: (_) => NewBankAccountDialog(seedName: typed),
);
