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

/// What a bank account can be: every value `bank_accounts.account_type`
/// accepts, in the words somebody would use for it.
///
/// This map and the CHECK constraint on that column have to agree, and
/// for a long time they did not. `fixed_deposit` was offered here and
/// has never been a permitted value in any migration, so choosing it
/// produced a constraint violation at save — the one option on the
/// list that could not work. And `cash` and `ewallet` were permitted
/// by the database and offered nowhere, so petty cash could be paid
/// from only by somebody who inserted the row by hand.
///
/// `scripts/check_bank_account_types.py` now compares the two on every
/// run, because a mismatch in one direction is a save that fails and
/// in the other a feature nobody can reach — and neither says so.
///
/// Cash and e-wallet accounts need no bank name and no account number;
/// those fields have no validator for that reason.
const bankAccountTypes = <String, String>{
  'current': 'Current',
  'savings': 'Savings',
  'credit_card': 'Credit card',
  'cash': 'Cash or petty cash',
  'ewallet': 'E-wallet',
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

  /// The chart account this is being registered against, when somebody
  /// picked one off the list below. `0689`.
  ///
  /// Null means the ordinary path: `upsert_bank_account` opens an
  /// account in the bank range and numbers it. Set means the account
  /// already exists and is being adopted, which is what the report
  /// this came from needed — a sub-account added on the chart and then
  /// looked for in a bank dropdown.
  String? _accountId;
  String? _accountCode;

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
      // SCROLLABLE, since `0689`. The form was already close to the
      // height a dialog gets on a phone, and the section offering the
      // accounts already on the chart pushed it 38 pixels over — which
      // Flutter reports as a test failure and a release build simply
      // CLIPS, taking the Save button with it.
      //
      // An `AlertDialog`'s content is not a scroll view of its own, so
      // this is not a viewport nested inside one.
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                _accountId == null
                    ? 'Not on file yet. Fill this in and it will be used. '
                        'An account on the chart is opened for it '
                        'automatically, in the bank range. Petty cash and '
                        'e-wallets belong here too — set the kind below '
                        'and leave the bank and number empty.'
                    : 'Registering $_accountCode, which is already on '
                        'your chart. No new chart account is opened, and '
                        'whatever is already posted to it stays where it '
                        'is.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 16),
              _AlreadyOnTheChart(
                chosen: _accountId,
                onChoose: (id, code, name) => setState(() {
                  _accountId = id;
                  _accountCode = code;
                  if (_name.text.trim().isEmpty) _name.text = name;
                }),
                onClear: () => setState(() {
                  _accountId = null;
                  _accountCode = null;
                }),
              ),
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
                      initialValue: _type,
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
        // Null on the ordinary path, which is what makes
        // `upsert_bank_account` open one. `0689`.
        accountId: _accountId,
      );
      // Every bank picker reads this, and the chart gained an account,
      // so both lists are re-read.
      ref.invalidate(bankAccountsProvider);
      ref.invalidate(accountsProvider);
      // One fewer waiting to be registered, whichever path was taken —
      // the ordinary one opens a chart account that is immediately
      // registered, so it must not appear on the list either.
      ref.invalidate(unregisteredBankAccountsProvider);
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

/// The accounts somebody already added on the chart, offered here.
///
/// `0689`. This is the whole of the fix for a report that read "BANK
/// ACCOUNT NOT SHOWING": a bank account in this product is two records,
/// the chart of accounts screen makes one of them, and until now
/// nothing anywhere connected the two. Somebody adds a sub-account
/// under Bank, goes to record a collection, and the dropdown does not
/// mention it — correctly, and with no way to find out why.
///
/// It OFFERS rather than decides. A `bank_accounts` row carries things
/// a chart account knows nothing about — the bank, the number, whether
/// it is a current account or a credit card, whether it is a CLIENT
/// account, which for a solicitor is a statutory distinction and not a
/// label. Creating one automatically would mean inventing those, and an
/// account silently created as an ordinary current account in a law
/// firm's chart is the mistake the Solicitors' Accounts Rules exist to
/// prevent.
///
/// Draws nothing when there is nothing waiting, which is the ordinary
/// case and should not cost a heading.
class _AlreadyOnTheChart extends ConsumerWidget {
  const _AlreadyOnTheChart({
    required this.chosen,
    required this.onChoose,
    required this.onClear,
  });

  final String? chosen;
  final void Function(String id, String code, String name) onChoose;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // One chosen already: the sentence above says which, and a list
    // offering the rest would invite changing it mid-form.
    if (chosen != null) {
      return Align(
        alignment: Alignment.centerLeft,
        child: TextButton(
          key: const ValueKey('chart-account-clear'),
          onPressed: onClear,
          child: const Text('Open a new chart account instead'),
        ),
      );
    }

    // `valueOrNull`, not `.value`. An error here is a list that could
    // not be read, and this section is an OFFER -- the form underneath
    // works perfectly well without it, so a failed read should draw
    // nothing rather than throw into a dialog somebody is typing in.
    final waiting =
        ref.watch(unregisteredBankAccountsProvider).valueOrNull ?? const [];
    if (waiting.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Already on your chart',
            style: Theme.of(context).textTheme.titleSmall),
        Text(
          'These can hold money but no bank account points at them yet, '
          'so nothing lists them. Register one instead of opening '
          'another.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 4),
        for (final a in waiting)
          ListTile(
            key: ValueKey('chart-account-${a['code']}'),
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: Text('${a['code']} — ${a['name']}'),
            trailing: TextButton(
              onPressed: () => onChoose(
                '${a['account_id']}',
                '${a['code']}',
                '${a['name']}',
              ),
              child: const Text('Register'),
            ),
          ),
        const Divider(height: 24),
      ],
    );
  }
}
