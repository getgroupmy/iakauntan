import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/error_text.dart';
import '../../core/format.dart';
import '../../core/providers.dart';

/// Add an account to the chart without leaving what you were posting.
///
/// The same argument as `NewItemDialog` and `NewContactDialog`, and it
/// arrived the same way: somebody typing an expense reached for an
/// account that is not on the chart yet, and the box said "Nothing
/// matches that" and stopped. The chart of accounts is a list a company
/// extends — a new expense heading, a new bank, a new reserve — and the
/// answer to "it is not there" cannot be "abandon this and go to
/// Settings".
///
/// WHAT IT ASKS FOR is a number, a name, and where it sits. Every one of
/// those decides something no default can guess: the number decides
/// where it appears in every report, and the type and subtype decide
/// which statement it lands on. `upsert_account` requires all four.
///
/// WHAT IT GUESSES is the type, from the number. The chart is numbered
/// by convention — 1xxx asset, 2xxx liability, 3xxx equity, 4xxx
/// revenue, 5xxx and 6xxx expense — which the Settings card already
/// states as helper text. Guessing it from a typed "6210" saves the
/// step that is right nine times in ten, in a box that is still there
/// to be corrected.
class NewAccountDialog extends ConsumerStatefulWidget {
  const NewAccountDialog({super.key, this.seed});

  /// What was typed into the picker: a number, or a name.
  final String? seed;

  @override
  ConsumerState<NewAccountDialog> createState() => _NewAccountDialogState();
}

/// Which subtypes belong to which type.
///
/// The same table as the Settings card, for the same reason it gives:
/// offering all twenty-odd against every type is how an expense ends up
/// filed as share capital and the balance sheet stops making sense.
const accountSubtypes = <String, List<String>>{
  'asset': [
    'current_asset',
    'bank',
    'cash',
    'accounts_receivable',
    'inventory',
    'fixed_asset',
    'accumulated_depreciation',
    'other_asset',
  ],
  'liability': [
    'current_liability',
    'accounts_payable',
    'tax_payable',
    'long_term_liability',
    'other_liability',
  ],
  'equity': ['share_capital', 'retained_earnings', 'reserves', 'drawings'],
  'revenue': ['sales', 'other_income'],
  'expense': [
    'cost_of_sales',
    'operating_expense',
    'payroll_expense',
    'depreciation_expense',
    'finance_cost',
    'tax_expense',
    'other_expense',
  ],
};

/// What kind of account a number says it is.
///
/// Pure, and asserted in `app/test/new_account_test.dart`. The chart is
/// numbered by a convention every Malaysian bookkeeper uses and the
/// Settings card already documents: 1xxx asset, 2xxx liability, 3xxx
/// equity, 4xxx revenue, 5xxx and 6xxx expense.
///
/// It returns null rather than a guess for anything that is not a
/// number in that range — a wrong guess silently filed on the wrong
/// statement is worse than no guess at all, and the caller falls back
/// to asking.
String? accountTypeFromCode(String code) {
  final trimmed = code.trim();
  if (trimmed.isEmpty || !RegExp(r'^\d').hasMatch(trimmed)) return null;
  return switch (trimmed[0]) {
    '1' => 'asset',
    '2' => 'liability',
    '3' => 'equity',
    '4' => 'revenue',
    '5' || '6' => 'expense',
    _ => null,
  };
}

/// Whether what was typed into the picker was a NUMBER or a NAME.
///
/// The two boxes on the dialog are seeded differently, and which one
/// gets the seed is decided here: somebody who typed "6210" was
/// reaching for a code, and somebody who typed "Printing" was reaching
/// for a name.
bool looksLikeAccountCode(String typed) =>
    RegExp(r'^\d{1,10}$').hasMatch(typed.trim());

class _NewAccountDialogState extends ConsumerState<NewAccountDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _code;
  late final TextEditingController _name;
  late String _type;
  late String _subtype;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final seed = widget.seed?.trim() ?? '';
    final isCode = looksLikeAccountCode(seed);
    _code = TextEditingController(text: isCode ? seed : '');
    _name = TextEditingController(text: isCode ? '' : seed);
    _type = accountTypeFromCode(seed) ?? 'expense';
    _subtype = accountSubtypes[_type]!.first;
  }

  @override
  void dispose() {
    _code.dispose();
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final choices = accountSubtypes[_type] ?? const <String>[];

    return AlertDialog(
      title: const Text('New account'),
      content: SizedBox(
        width: 440,
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Not on the chart yet. Fill this in and the posting will '
                'use it.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _code,
                autofocus: _code.text.isEmpty,
                decoration: const InputDecoration(
                  labelText: 'Number',
                  helperText:
                      'Four digits, in the range its kind sits in '
                      '— 6xxx for an expense, 1xxx for an asset.',
                  helperMaxLines: 2,
                ),
                keyboardType: TextInputType.number,
                // The kind follows the number, which is the convention
                // the chart is numbered by. Typed into an open box, so
                // a company that numbers differently just corrects it.
                onChanged: (v) {
                  final guess = accountTypeFromCode(v);
                  if (guess == null || guess == _type) return;
                  setState(() {
                    _type = guess;
                    _subtype = accountSubtypes[_type]!.first;
                  });
                },
                validator: (v) => (v ?? '').trim().isEmpty
                    ? 'Every account needs a number. It is what the '
                          'reports are ordered by.'
                    : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _name,
                autofocus: _code.text.isNotEmpty,
                decoration: const InputDecoration(
                  labelText: 'Name',
                  hintText: 'Printing and stationery',
                ),
                validator: (v) =>
                    (v ?? '').trim().isEmpty ? 'And a name.' : null,
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                isExpanded: true,
                initialValue: _type,
                decoration: const InputDecoration(labelText: 'Kind'),
                items: [
                  for (final t in accountSubtypes.keys)
                    DropdownMenuItem(value: t, child: Text(Fmt.label(t))),
                ],
                onChanged: (v) => setState(() {
                  _type = v ?? 'expense';
                  _subtype = accountSubtypes[_type]!.first;
                }),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                isExpanded: true,
                initialValue:
                    choices.contains(_subtype) ? _subtype : choices.first,
                decoration: const InputDecoration(labelText: 'Where it sits'),
                items: [
                  for (final s in choices)
                    DropdownMenuItem(value: s, child: Text(Fmt.label(s))),
                ],
                onChanged: (v) => setState(() => _subtype = v ?? choices.first),
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
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

  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final repo = ref.read(repoProvider);
    if (repo == null) return;
    final choices = accountSubtypes[_type] ?? const <String>[];

    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final id = await repo.upsertAccount(
        code: _code.text.trim(),
        name: _name.text.trim(),
        type: _type,
        subtype: choices.contains(_subtype) ? _subtype : choices.first,
      );
      // Every account picker reads this, so the row just made is
      // findable from the box it was made in.
      ref.invalidate(accountsProvider);
      if (mounted) Navigator.pop(context, id);
    } catch (e) {
      // Shown here rather than thrown away: the likely failures are a
      // number already in use and a number outside its type's range,
      // and both are things the person can fix without losing the
      // posting behind this dialog.
      if (mounted) setState(() => _error = errorText(e));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }
}

/// Add an account from the box that wanted one, and return its id.
Future<String?> createAccountFromPicker(
  BuildContext context, {
  required String typed,
}) => showDialog<String>(
  context: context,
  builder: (_) => NewAccountDialog(seed: typed),
);
