import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/models.dart';
import '../../data/repository.dart';

/// Which MBRS element each account reports under.
///
/// `fs_account_map` holds the deviations from the default mapping and
/// nothing in the app could read or write one: `fsAccountMap`,
/// `setFsAccountMap` and `mbrsElements` all had no caller. A standard
/// chart needs no deviation, which is why this went unnoticed — but a
/// company that repurposed an account, or created one without a
/// subtype, had its figures land under whatever `fs_default_element`
/// decided and no way to move them. The numbers lodged with SSM would
/// be wrong with no remedy inside the product.

/// The element an account reports under when the company has said
/// nothing, mirroring `app.fs_default_element`.
///
/// `accounts.account_subtype` is very nearly the taxonomy already,
/// which is the whole reason the override table is usually empty.
/// Mirrored here so the screen can show what an account will do before
/// anybody overrides it, and say plainly when an override changes
/// nothing.
String? fsDefaultElement(String type, String? subtype) {
  switch (subtype) {
    // Accumulated depreciation lands on the same element as the cost it
    // relieves: the face of the statement shows carrying amount, and
    // the split is a note.
    case 'fixed_asset':
    case 'accumulated_depreciation':
      return 'PropertyPlantAndEquipment';
    case 'other_asset':
      return 'OtherNonCurrentAssets';
    case 'inventory':
      return 'Inventories';
    case 'accounts_receivable':
      return 'TradeAndOtherReceivables';
    case 'bank':
    case 'cash':
      return 'CashAndCashEquivalents';
    case 'current_asset':
      return 'OtherCurrentAssets';
    case 'accounts_payable':
      return 'TradeAndOtherPayables';
    case 'tax_payable':
      return 'CurrentTaxLiabilities';
    case 'current_liability':
      return 'OtherCurrentLiabilities';
    case 'long_term_liability':
      return 'LoansAndBorrowings';
    case 'other_liability':
      return 'OtherNonCurrentLiabilities';
    case 'share_capital':
      return 'ShareCapital';
    case 'reserves':
      return 'Reserves';
    // Drawings are debit-natural equity, so they come back negative
    // from the balance sheet and correctly reduce retained earnings
    // rather than needing a sign of their own.
    case 'retained_earnings':
    case 'drawings':
      return 'RetainedEarnings';
    case 'sales':
      return 'Revenue';
    case 'cost_of_sales':
      return 'CostOfSales';
    case 'other_income':
      return 'OtherIncome';
    case 'operating_expense':
      return 'AdministrativeExpenses';
    case 'payroll_expense':
      return 'StaffCosts';
    case 'depreciation_expense':
      return 'DepreciationAndAmortisation';
    case 'finance_cost':
      return 'FinanceCosts';
    case 'other_expense':
      return 'OtherOperatingExpenses';
    case 'tax_expense':
      return 'TaxExpense';
  }

  // No subtype at all: fall back on the type, so an account somebody
  // created without one still lands somewhere defensible rather than
  // vanishing off the face of the statement.
  switch (type) {
    case 'asset':
      return 'OtherCurrentAssets';
    case 'liability':
      return 'OtherCurrentLiabilities';
    case 'equity':
      return 'Reserves';
    case 'revenue':
      return 'OtherIncome';
    case 'expense':
      return 'OtherOperatingExpenses';
  }
  return null;
}

/// Which element an account actually reports under: the company's
/// override if it wrote one, the default otherwise.
String? fsElementFor({
  required String type,
  String? subtype,
  String? override,
}) =>
    override ?? fsDefaultElement(type, subtype);

/// Whether an override is doing anything.
///
/// A row that names the same element the default already gives is a
/// row somebody has to read and reason about for no gain, so it is
/// shown as what it is rather than as a deviation.
bool fsOverrideChangesAnything(
  String? override,
  String type,
  String? subtype,
) =>
    override != null && override != fsDefaultElement(type, subtype);

/// The override for one account, out of the deviations table.
String? fsOverrideFor(
  Iterable<Map<String, dynamic>> map,
  String accountId,
) {
  for (final row in map) {
    if (row['account_id'] == accountId) return row['element_code'] as String?;
  }
  return null;
}

/// The accounts whose figures actually reach a statement.
///
/// Headings carry no balance of their own, and an account nobody uses
/// any more still holds the history it was posted with — so a retired
/// account stays on the list, because last year's comparative comes
/// from it.
List<Account> mappableAccounts(Iterable<Account> accounts) =>
    accounts.where((a) => !a.isGroup).toList();

/// How the chart maps, and how to correct it.
Future<bool> showFsMapping(BuildContext context) async =>
    await showDialog<bool>(
      context: context,
      builder: (_) => const _MappingDialog(),
    ) ??
    false;

class _MappingDialog extends ConsumerStatefulWidget {
  const _MappingDialog();

  @override
  ConsumerState<_MappingDialog> createState() => _MappingDialogState();
}

class _MappingDialogState extends ConsumerState<_MappingDialog> {
  final _search = TextEditingController();
  bool _onlyOverridden = false;
  bool _changed = false;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _remap(Account a, String? current) async {
    final elements =
        ref.read(mbrsElementsProvider).valueOrNull ??
            const <Map<String, dynamic>>[];
    if (elements.isEmpty) return;

    final chosen = await showDialog<String?>(
      context: context,
      builder: (ctx) {
        String? value = current;
        return StatefulBuilder(
          builder: (ctx, setLocal) => AlertDialog(
            title: Text('${a.code} · ${a.name}'),
            content: SizedBox(
              width: 460,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Without an override this reports under '
                    '${fsDefaultElement(a.accountType, a.accountSubtype) ?? "nothing"}, '
                    'from its subtype.',
                    style: Theme.of(ctx).textTheme.bodySmall,
                  ),
                  const SizedBox(height: Space.md),
                  DropdownButtonFormField<String?>(
                    key: const ValueKey('fs-element'),
                    value: value,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: 'Reports as'),
                    items: [
                      const DropdownMenuItem<String?>(
                        value: null,
                        child: Text('The default for its subtype'),
                      ),
                      for (final e in elements)
                        DropdownMenuItem<String?>(
                          value: e['code'] as String?,
                          child: Text(
                            '${e['label'] ?? e['code']}',
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                    onChanged: (v) => setLocal(() => value = v),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(current),
                child: const Text('Cancel'),
              ),
              FilledButton(
                key: const ValueKey('fs-element-save'),
                // Popping the value straight would make "the default"
                // indistinguishable from cancelling, since both are
                // null. The sentinel is the empty string.
                onPressed: () => Navigator.of(ctx).pop(value ?? ''),
                child: const Text('Set'),
              ),
            ],
          ),
        );
      },
    );
    if (chosen == null || chosen == current || !mounted) return;

    final ok = await runWithFeedback(
      context,
      action: () => ref
          .read(repoProvider)!
          .setFsAccountMap(a.id, chosen.isEmpty ? null : chosen),
      successMessage: chosen.isEmpty ? 'Back to the default' : 'Remapped',
    );
    if (ok && mounted) {
      _changed = true;
      ref.invalidate(fsAccountMapProvider);
    }
  }

  @override
  Widget build(BuildContext context) {
    final accounts = ref.watch(accountsProvider).valueOrNull ?? const <Account>[];
    final map = ref.watch(fsAccountMapProvider).valueOrNull ??
        const <Map<String, dynamic>>[];
    final canWrite = ref.watch(canWriteProvider);
    final needle = _search.text.trim().toLowerCase();

    final rows = [
      for (final a in mappableAccounts(accounts))
        if (needle.isEmpty ||
            a.code.toLowerCase().contains(needle) ||
            a.name.toLowerCase().contains(needle))
          a,
    ].where((a) {
      if (!_onlyOverridden) return true;
      return fsOverrideChangesAnything(
        fsOverrideFor(map, a.id),
        a.accountType,
        a.accountSubtype,
      );
    }).toList();

    return AlertDialog(
      title: const Text('How the chart reports'),
      content: SizedBox(
        width: 640,
        height: 520,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Each account lands on an MBRS element from its subtype. '
              'Where that is wrong for this company, say so here — the '
              'override is what the export uses.',
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: context.scheme.onSurfaceVariant),
            ),
            const SizedBox(height: Space.sm),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    key: const ValueKey('fs-search'),
                    controller: _search,
                    onChanged: (_) => setState(() {}),
                    decoration: const InputDecoration(
                      isDense: true,
                      prefixIcon: Icon(Icons.search, size: 18),
                      hintText: 'Code or name',
                    ),
                  ),
                ),
                const SizedBox(width: Space.md),
                FilterChip(
                  key: const ValueKey('fs-only-overridden'),
                  label: const Text('Changed only'),
                  selected: _onlyOverridden,
                  onSelected: (v) => setState(() => _onlyOverridden = v),
                ),
              ],
            ),
            const SizedBox(height: Space.sm),
            Expanded(
              child: rows.isEmpty
                  ? Center(
                      child: Text(
                        _onlyOverridden
                            ? 'Nothing has been moved. A standard chart '
                                'needs no override.'
                            : 'No account matches that.',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    )
                  : ListView.separated(
                      itemCount: rows.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (_, i) {
                        final a = rows[i];
                        final override = fsOverrideFor(map, a.id);
                        final moved = fsOverrideChangesAnything(
                          override,
                          a.accountType,
                          a.accountSubtype,
                        );
                        return ListTile(
                          dense: true,
                          onTap: canWrite ? () => _remap(a, override) : null,
                          title: Text('${a.code} ${a.name}'),
                          subtitle: Text(
                            fsElementFor(
                                  type: a.accountType,
                                  subtype: a.accountSubtype,
                                  override: override,
                                ) ??
                                'nowhere',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight:
                                  moved ? FontWeight.w600 : FontWeight.normal,
                            ),
                          ),
                          trailing: moved
                              ? const StatusChip('changed', compact: true)
                              : null,
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(_changed),
          child: const Text('Close'),
        ),
      ],
    );
  }
}
