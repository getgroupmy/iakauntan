import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/picker_options.dart';
import '../../core/providers.dart';
import '../../core/searchable_picker.dart';
import '../../core/skeletons.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/repository.dart';
import '../banking/new_bank_account_dialog.dart';

/// The seven kinds a tender can be, in the words a shopkeeper uses.
///
/// `app.pos_tender_kind` since `0208`. The labels are here rather than
/// in the database because they are English for a screen, and the till
/// groups a drawer count by `kind` whatever this says.
const Map<String, String> tenderKinds = {
  'cash': 'Cash',
  'card': 'Card',
  'ewallet': 'E-wallet',
  'bank_transfer': 'Bank transfer',
  'voucher': 'Voucher',
  'on_account': 'On account',
  'loyalty': 'Points',
};

/// Whether money actually arrives when somebody pays this way.
///
/// The rule is `0732`'s and it is enforced in SQL —
/// `upsert_pos_tender_type` refuses a bank account on either of these
/// kinds, and `app.tender_type_settlement_account` leaves them alone
/// rather than filling one in. This is the same question asked in Dart
/// so the form does not offer a field the server will refuse.
///
/// ON ACCOUNT is the customer owing it: `complete_pos_sale` writes no
/// receipt at all for a basket that is wholly on account. POINTS come
/// off the basket, and `0212` gives a basket cleared by them a receipt
/// for zero so the sale is a completed sale rather than a stuck one —
/// no money moved either way.
bool tenderTakesMoney(String kind) =>
    kind != 'on_account' && kind != 'loyalty';

/// What a tender does, in one line, for the list and the tests both.
///
/// Pure and exported for the reason `scaleLayout` is: a summary the
/// screen computes and a summary a test computes have to be the same
/// summary, or the test is about something nobody sees.
String tenderSummary(Map<String, dynamic> row, {String? accountName}) {
  final kind = '${row['kind']}';
  final parts = <String>[tenderKinds[kind] ?? kind];

  if (!tenderTakesMoney(kind)) {
    parts.add('nothing is banked');
  } else if (accountName != null && accountName.isNotEmpty) {
    parts.add(
      kind == 'cash' || row['counts_in_drawer'] == true
          ? 'into $accountName'
          : 'settles into $accountName',
    );
  } else {
    // The state `0731` refuses to post against. A shop with no bank
    // account at all reaches it, and saying so here is kinder than a
    // red snackbar at the till.
    parts.add('NOWHERE YET — add a bank account');
  }

  final habits = <String>[
    if (row['counts_in_drawer'] == true) 'counts in the drawer',
    if (row['gives_change'] == true) 'gives change',
    if (row['opens_drawer'] == true) 'opens the drawer',
  ];
  if (habits.isNotEmpty) parts.add(habits.join(', '));

  return parts.join(' · ');
}

/// Ways of paying at the till, and where each one's money lands.
///
/// `0732`. This screen exists because `0731` found that every
/// `pos_tender_types` row in production had a null bank account and
/// nobody could have set one: the table is read by the till and was
/// written only by the demo seeders. The rule fills in a sensible
/// answer — the drawer for cash, the settlement account for a card —
/// and this is where a shop disagrees with it.
class TendersScreen extends ConsumerStatefulWidget {
  const TendersScreen({super.key});

  @override
  ConsumerState<TendersScreen> createState() => _TendersScreenState();
}

class _TendersScreenState extends ConsumerState<TendersScreen> {
  void _reload() {
    ref.invalidate(posTenderTypesAdminProvider);
    // The till's own list as well, or a tender switched off here is
    // still on a button over there until something else refetches.
    ref.invalidate(posTenderTypesProvider);
  }

  Future<void> _edit(Map<String, dynamic>? existing) async {
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _TenderSheet(tender: existing),
    );
    if (saved == true) _reload();
  }

  Future<void> _remove(Map<String, dynamic> row) async {
    final ok = await runWithFeedback(
      context,
      action: () =>
          ref.read(repoProvider)!.deletePosTenderType(row['id'] as String),
      successMessage: 'Removed.',
    );
    if (ok) _reload();
  }

  @override
  Widget build(BuildContext context) {
    final tenders = ref.watch(posTenderTypesAdminProvider);
    final banks = ref.watch(bankAccountsProvider).valueOrNull ?? const [];

    return Scaffold(
      appBar: AppBar(title: const Text('Ways of paying')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _edit(null),
        icon: const Icon(Icons.add),
        label: const Text('Tender'),
      ),
      body: AsyncView<List<Map<String, dynamic>>>(
        value: tenders,
        onRetry: _reload,
        skeleton: const ListSkeleton(rows: 4, leading: false),
        builder: (rows) {
          if (rows.isEmpty) {
            return const EmptyState(
              icon: Icons.payments_outlined,
              title: 'No ways of paying yet',
              message:
                  'A till needs at least one button. Add cash first — it '
                  'goes in the drawer and gives change — and a card, which '
                  'settles into the bank a few days later.',
            );
          }
          return ListView.separated(
            itemCount: rows.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, i) {
              final row = rows[i];
              return ListTile(
                title: Text('${row['name']} · ${row['code']}'),
                subtitle: Text(
                  tenderSummary(
                    row,
                    accountName: bankAccountName(banks, row['bank_account_id']),
                  ),
                ),
                isThreeLine: true,
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (row['is_active'] != true)
                      const Chip(
                        label: Text('Off'),
                        visualDensity: VisualDensity.compact,
                      ),
                    IconButton(
                      tooltip: 'Remove',
                      icon: const Icon(Icons.delete_outline),
                      onPressed: () => _remove(row),
                    ),
                  ],
                ),
                onTap: () => _edit(row),
              );
            },
          );
        },
      ),
    );
  }
}

/// The name of a bank account, or null where the id names none.
///
/// Exported so the list and its test read the rows the same way.
String? bankAccountName(List<Map<String, dynamic>> banks, Object? id) {
  if (id == null) return null;
  for (final b in banks) {
    if ('${b['id']}' == '$id') return '${b['name']}';
  }
  return null;
}

class _TenderSheet extends ConsumerStatefulWidget {
  const _TenderSheet({required this.tender});

  final Map<String, dynamic>? tender;

  @override
  ConsumerState<_TenderSheet> createState() => _TenderSheetState();
}

class _TenderSheetState extends ConsumerState<_TenderSheet> {
  late final _name = TextEditingController(
    text: '${widget.tender?['name'] ?? ''}',
  );
  late final _code = TextEditingController(
    text: '${widget.tender?['code'] ?? ''}',
  );
  late String _kind = '${widget.tender?['kind'] ?? 'cash'}';
  late String? _mode = widget.tender?['payment_mode_code'] as String?;
  late String? _bank = widget.tender?['bank_account_id'] as String?;
  late bool _drawer = widget.tender?['counts_in_drawer'] == true;
  late bool _change = widget.tender?['gives_change'] == true;
  late bool _opens = widget.tender?['opens_drawer'] == true;
  late bool _active = widget.tender?['is_active'] != false;

  bool get _isNew => widget.tender == null;

  @override
  void initState() {
    super.initState();
    // A NEW tender starts with the habits its kind usually has, which
    // is what `upsert_pos_tender_type` defaults to when it is not told.
    // An existing one keeps whatever the shop chose, including the
    // cheque somebody puts in the drawer.
    if (_isNew) {
      _drawer = _kind == 'cash';
      _change = _kind == 'cash';
      _opens = _kind == 'cash';
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _code.dispose();
    super.dispose();
  }

  void _kindChanged(String kind) {
    setState(() {
      _kind = kind;
      if (_isNew) {
        _drawer = kind == 'cash';
        _change = kind == 'cash';
        _opens = kind == 'cash';
      }
      // `_bank` is deliberately NOT cleared here. A mutation run found
      // the line that did it unobservable and then slightly harmful:
      // `_save` already sends null for a kind that takes no money, so
      // clearing was defence in depth -- and it meant somebody who
      // looked at On account and changed their mind back to Card lost
      // the account they had picked.
    });
  }

  Future<void> _save() async {
    final ok = await runWithFeedback(
      context,
      action: () => ref.read(repoProvider)!.savePosTenderType(
            id: widget.tender?['id'] as String?,
            code: _code.text.trim(),
            name: _name.text.trim(),
            kind: _kind,
            paymentMode: _mode,
            bankAccountId: tenderTakesMoney(_kind) ? _bank : null,
            countsInDrawer: _drawer,
            givesChange: _change,
            opensDrawer: _opens,
            active: _active,
          ),
      successMessage: 'Saved.',
    );
    if (ok && mounted) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final banks = ref.watch(bankAccountsProvider).valueOrNull ?? const [];
    final modes = ref.watch(paymentModesProvider).valueOrNull ?? const [];
    final takesMoney = tenderTakesMoney(_kind);
    final ready = _name.text.trim().isNotEmpty && _code.text.trim().isNotEmpty;

    return Padding(
      padding: EdgeInsets.only(
        left: Space.lg,
        right: Space.lg,
        top: Space.lg,
        bottom: MediaQuery.of(context).viewInsets.bottom + Space.lg,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _isNew ? 'A way of paying' : 'Edit ${widget.tender?['name']}',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: Space.md),
            TextField(
              controller: _name,
              decoration: const InputDecoration(
                labelText: 'Name *',
                helperText: 'What the button says. "Tunai", "Kad", "TnG".',
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: Space.md),
            TextField(
              controller: _code,
              textCapitalization: TextCapitalization.characters,
              decoration: const InputDecoration(
                labelText: 'Code *',
                helperText: 'Short, and what every report groups by.',
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: Space.md),
            DropdownButtonFormField<String>(
              initialValue: _kind,
              // Or 'Bank transfer' overflows the row rather than
              // ellipsising, which `dropdown_census_test.dart` checks
              // for every one of these in the app.
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Kind'),
              items: [
                for (final e in tenderKinds.entries)
                  DropdownMenuItem(value: e.key, child: Text(e.value)),
              ],
              onChanged: (v) => _kindChanged(v ?? 'cash'),
            ),
            const SizedBox(height: Space.md),
            SearchablePicker<String>(
              options: [
                for (final m in modes)
                  PickerOption<String>(
                    value: '${m['code']}',
                    label: '${m['code']} · ${m['description']}',
                  ),
              ],
              value: _mode,
              label: 'LHDN payment mode',
              hint: 'What an e-Invoice raised from a sale reports',
              allowEmpty: true,
              emptyLabel: 'Not reported',
              onChanged: (v) => setState(() => _mode = v),
            ),
            const SizedBox(height: Space.md),
            if (takesMoney)
              SearchablePicker<String>
                (
                options: bankPickerOptions(banks),
                value: _bank,
                label: 'Money lands in *',
                hint: 'The drawer for cash; the bank for a card',
                helperText:
                    'A card or e-wallet settles here days later, net of '
                    'the fee. Cash belongs in a till account — one of type '
                    'cash — not in the current account.',
                createLabel: 'Add bank account',
                onCreate: (typed) =>
                    createBankAccountFromPicker(context, typed: typed),
                onChanged: (v) => setState(() => _bank = v),
              )
            else
              const Padding(
                padding: EdgeInsets.symmetric(vertical: Space.sm),
                child: Text(
                  'Nothing is banked. On account is the customer owing it; '
                  'points come off the basket. Neither is money arriving, '
                  'so there is no account to name.',
                ),
              ),
            const SizedBox(height: Space.sm),
            SwitchListTile(
              value: _drawer,
              onChanged: (v) => setState(() => _drawer = v),
              title: const Text('Counts in the drawer'),
              subtitle: const Text(
                'A cash-up expects this money to be in the till. A cheque '
                'taken over the counter is in there too.',
              ),
            ),
            SwitchListTile(
              value: _change,
              onChanged: (v) => setState(() => _change = v),
              title: const Text('Gives change'),
            ),
            SwitchListTile(
              value: _opens,
              onChanged: (v) => setState(() => _opens = v),
              title: const Text('Opens the drawer'),
            ),
            SwitchListTile(
              value: _active,
              onChanged: (v) => setState(() => _active = v),
              title: const Text('Offered at the till'),
              subtitle: const Text(
                'Switch off rather than remove: a tender that has taken '
                'money stays on the books.',
              ),
            ),
            const SizedBox(height: Space.md),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Cancel'),
                ),
                const SizedBox(width: Space.sm),
                FilledButton(
                  onPressed: ready ? _save : null,
                  child: const Text('Save'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
