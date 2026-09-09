import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/export_log.dart';
import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/models.dart';
import 'chart_export.dart';

/// The company's own chart of accounts.
///
/// This card used to be a count by type — "14 assets, 9 liabilities" —
/// and nothing else, while the database had allowed insert, update and
/// delete for anyone who may post since the schema was laid down. So a
/// company that wanted an account for a new line of business held a
/// permission it could not reach.
///
/// The refusals are the server's and are left to it. Three of them are
/// worth knowing about, because they are not obvious:
///
///   * posting resolves accounts **by number**, so a number the ledger
///     names cannot be changed — the account can still be renamed;
///   * an account with postings cannot change what kind of account it
///     is, because that flips its sign in every report ever run;
///   * an account with history is deactivated, never deleted.
class ChartOfAccountsCard extends ConsumerWidget {
  const ChartOfAccountsCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final accounts = ref.watch(accountsProvider);
    final canEdit = ref.watch(canPostProvider);

    Future<void> edit([Account? existing]) async {
      final saved = await showDialog<bool>(
        context: context,
        builder: (_) => _AccountDialog(existing: existing),
      );
      if (saved == true) ref.invalidate(accountsProvider);
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Space.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SectionHeader(
              'Chart of accounts',
              subtitle: 'Malaysian SME template, MPERS aligned',
              // Three doors, in the order somebody uses them: take the
              // chart away, bring one in, add one account. Export is
              // offered to anybody who can see the chart -- it is the
              // same list already on the screen, and refusing to let
              // somebody save what they are looking at is not a
              // control. The other two need the permission the server
              // asks for.
              action: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextButton.icon(
                    key: const ValueKey('chart-export'),
                    onPressed: () => _export(context, ref, accounts.valueOrNull),
                    icon: const Icon(Icons.download_outlined, size: 18),
                    label: const Text('Export'),
                  ),
                  if (canEdit) ...[
                    TextButton.icon(
                      key: const ValueKey('chart-import'),
                      onPressed: () => context.go('/import'),
                      icon: const Icon(Icons.upload_file_outlined, size: 18),
                      label: const Text('Import'),
                    ),
                    TextButton.icon(
                      onPressed: () => edit(),
                      icon: const Icon(Icons.add, size: 18),
                      label: const Text('Add'),
                    ),
                  ],
                ],
              ),
            ),
            AsyncView(
              value: accounts,
              onRetry: () => ref.invalidate(accountsProvider),
              loading: const LinearProgressIndicator(),
              builder: (list) {
                // Grouped by type, in the order a chart is read: assets,
                // liabilities, equity, revenue, expense. A flat list of
                // a hundred rows is a list nobody scrolls.
                const order = [
                  'asset',
                  'liability',
                  'equity',
                  'revenue',
                  'expense',
                ];
                return Column(
                  children: [
                    for (final type in order)
                      _TypeGroup(
                        type: type,
                        accounts: list
                            .where((a) => a.accountType == type)
                            .toList(),
                        canEdit: canEdit,
                        onEdit: edit,
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

/// Saves the chart as CSV, or leaves it on the clipboard.
///
/// Nothing downloads on a phone, so the clipboard is the fallback
/// rather than a message saying the export happened when it did not —
/// the same arrangement `reports_screen.dart` uses.
Future<void> _export(
  BuildContext context,
  WidgetRef ref,
  List<Account>? accounts,
) async {
  final messenger = ScaffoldMessenger.of(context);
  if (accounts == null || accounts.isEmpty) {
    messenger.showSnackBar(
      const SnackBar(content: Text('The chart has not loaded yet.')),
    );
    return;
  }
  final csv = chartOfAccountsCsv(accounts);
  final saved = await exportTextFile(
    ref,
    chartExportFilename(
      ref.read(currentOrgProvider).valueOrNull?.name,
      DateTime.now(),
    ),
    'text/csv',
    csv,
    what: 'Chart of accounts',
    detail: '${accounts.length} accounts, as CSV',
  );
  if (!saved) await Clipboard.setData(ClipboardData(text: csv));
  messenger.showSnackBar(
    SnackBar(content: Text(saved ? 'Downloaded' : 'Copied to the clipboard')),
  );
}

class _TypeGroup extends ConsumerWidget {
  const _TypeGroup({
    required this.type,
    required this.accounts,
    required this.canEdit,
    required this.onEdit,
  });

  final String type;
  final List<Account> accounts;
  final bool canEdit;
  final Future<void> Function([Account?]) onEdit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (accounts.isEmpty) return const SizedBox.shrink();

    return ExpansionTile(
      tilePadding: EdgeInsets.zero,
      title: Text(Fmt.label(type)),
      subtitle: Text(
        '${accounts.where((a) => !a.isGroup).length} accounts',
        style: Theme.of(context).textTheme.bodySmall,
      ),
      children: [
        for (final a in accounts)
          ListTile(
            dense: true,
            contentPadding: const EdgeInsets.only(left: 8),
            onTap: canEdit ? () => onEdit(a) : null,
            title: Text(
              '${a.code}  ${a.name}',
              style: TextStyle(
                fontWeight: a.isGroup ? FontWeight.w600 : null,
                // A deactivated account is still in the chart and still
                // holds its postings; it just cannot be chosen again.
                color: a.isActive
                    ? null
                    : Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            subtitle: a.isActive
                ? null
                : const Text('Retired', style: TextStyle(fontSize: 11)),
            trailing: canEdit && !a.isGroup
                ? IconButton(
                    tooltip: 'Retire this account',
                    icon: const Icon(Icons.remove_circle_outline, size: 18),
                    onPressed: a.isActive
                        ? () => _retire(context, ref, a)
                        : null,
                  )
                : null,
          ),
      ],
    );
  }

  Future<void> _retire(BuildContext context, WidgetRef ref, Account a) async {
    final ok = await confirm(
      context,
      title: 'Retire ${a.code} ${a.name}?',
      message:
          'If nothing has ever been posted to it, it is removed. If '
          'anything has, it is switched off and keeps its history — an '
          'account with a balance cannot be deleted without the books '
          'stopping balancing.',
      confirmLabel: 'Retire',
      destructive: true,
    );
    if (!ok || !context.mounted) return;
    final repo = ref.read(repoProvider);
    if (repo == null) return;

    String? outcome;
    await runWithFeedback(
      context,
      doing: 'retire an account',
      // Said after the fact rather than before, because which of the two
      // happened is the server's to decide and the message would
      // otherwise be a guess.
      successMessage: null,
      action: () async => outcome = await repo.retireAccount(a.id),
    );
    ref.invalidate(accountsProvider);
    if (!context.mounted || outcome == null) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          outcome == 'deleted'
              ? '${a.code} removed — nothing had been posted to it'
              : '${a.code} switched off, and keeps its postings',
        ),
      ),
    );
  }
}

class _AccountDialog extends ConsumerStatefulWidget {
  const _AccountDialog({this.existing});

  final Account? existing;

  @override
  ConsumerState<_AccountDialog> createState() => _AccountDialogState();
}

class _AccountDialogState extends ConsumerState<_AccountDialog> {
  late final TextEditingController _code = TextEditingController(
    text: widget.existing?.code ?? '',
  );
  late final TextEditingController _name = TextEditingController(
    text: widget.existing?.name ?? '',
  );
  late String _type = widget.existing?.accountType ?? 'expense';
  late String _subtype = widget.existing?.accountSubtype ?? 'operating_expense';

  /// Which subtypes belong to which type. Offering all twenty-odd
  /// against every type is how an expense ends up filed as share
  /// capital, and the balance sheet stops making sense.
  static const _subtypes = <String, List<String>>{
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

  @override
  void dispose() {
    _code.dispose();
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final choices = _subtypes[_type] ?? const <String>[];

    return AlertDialog(
      title: Text(widget.existing == null ? 'New account' : 'Edit account'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _code,
              autofocus: widget.existing == null,
              decoration: const InputDecoration(
                labelText: 'Number',
                helperText:
                    'Four digits, in the range its type sits in — '
                    '6xxx for an expense, 1xxx for an asset.',
                helperMaxLines: 2,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _name,
              decoration: const InputDecoration(labelText: 'Name'),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              value: _type,
              decoration: const InputDecoration(labelText: 'Kind'),
              items: [
                for (final t in _subtypes.keys)
                  DropdownMenuItem(value: t, child: Text(Fmt.label(t))),
              ],
              onChanged: (v) => setState(() {
                _type = v ?? 'expense';
                _subtype = _subtypes[_type]!.first;
              }),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              value: choices.contains(_subtype) ? _subtype : choices.first,
              decoration: const InputDecoration(labelText: 'Where it sits'),
              items: [
                for (final s in choices)
                  DropdownMenuItem(value: s, child: Text(Fmt.label(s))),
              ],
              onChanged: (v) => setState(() => _subtype = v ?? choices.first),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () async {
            final repo = ref.read(repoProvider);
            if (repo == null) return;
            final done = await runWithFeedback(
              context,
              doing: 'change the chart of accounts',
              successMessage: 'Saved',
              action: () => repo.upsertAccount(
                code: _code.text.trim(),
                name: _name.text.trim(),
                type: _type,
                subtype: choices.contains(_subtype) ? _subtype : choices.first,
                id: widget.existing?.id,
              ),
            );
            if (done && context.mounted) Navigator.pop(context, true);
          },
          child: const Text('Save'),
        ),
      ],
    );
  }
}
