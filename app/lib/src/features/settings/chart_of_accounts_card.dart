import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/export_log.dart';
import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/row_actions.dart';
import '../../core/skeletons.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/models.dart';
import 'chart_export.dart';
import 'sub_account_dialog.dart';

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
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Space.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: const [
            SectionHeader(
              'Chart of accounts',
              subtitle: 'Malaysian SME template, MPERS aligned',
              action: _ChartActions(),
            ),
            _ChartBody(),
          ],
        ),
      ),
    );
  }
}

/// The chart of accounts, with a door of its own.
///
/// It had none. The chart lived on a card most of the way down
/// Settings, which is where a company's SETUP lives -- and the chart is
/// not setup, it is the thing an accountant opens to look something up.
/// Reported as a missing entry under General Ledger, which is exactly
/// where it belongs: that heading is the `accounting` module's, and
/// Journals, Reconcile and Withholding tax are already under it.
///
/// The same card's body, not a second copy of it. A chart with two
/// implementations is two charts, and the one nobody is looking at is
/// the one that goes stale.
class ChartOfAccountsScreen extends StatelessWidget {
  const ChartOfAccountsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Chart of accounts'),
        // `RowActions`, not three `TextButton.icon`s: Flutter CLIPS an
        // overflowing toolbar in a release build rather than reporting
        // it, and Export, Import and Add with their words on want more
        // than a 360-pixel phone has.
        actions: const [
          Padding(
            padding: EdgeInsets.only(right: Space.sm),
            child: _ChartActions(narrow: true),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(
          Space.lg,
          Space.lg,
          Space.lg,
          Space.xxl,
        ),
        children: const [
          Text('Malaysian SME template, MPERS aligned'),
          SizedBox(height: Space.lg),
          // OPEN, unlike the card. On a settings page the chart is one
          // card among a dozen and a collapsed summary is right. On a
          // screen whose entire purpose is the chart, five closed
          // headings and no accounts is a screen that answers nothing
          // until you have tapped it five times.
          _ChartBody(expanded: true),
        ],
      ),
    );
  }
}

/// Three doors, in the order somebody uses them: take the chart away,
/// bring one in, add one account.
///
/// Export is offered to anybody who can see the chart -- it is the same
/// list already on the screen, and refusing to let somebody save what
/// they are looking at is not a control. The other two need the
/// permission the server asks for.
class _ChartActions extends ConsumerWidget {
  const _ChartActions({this.narrow = false});

  /// On the screen's own toolbar, where there is far less room than
  /// beside a card's heading.
  final bool narrow;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final accounts = ref.watch(accountsProvider);
    final canEdit = ref.watch(canPostProvider);

    return RowActions(
      narrowAt: narrow ? 900 : 0,
      menuKey: 'chart-actions',
      actions: [
        RowAction(
          label: 'Export',
          actionKey: 'chart-export',
          icon: Icons.download_outlined,
          onTap: () => _export(context, ref, accounts.valueOrNull),
        ),
        if (canEdit) ...[
          RowAction(
            label: 'Import',
            actionKey: 'chart-import',
            icon: Icons.upload_file_outlined,
            onTap: () => context.go('/import'),
          ),
          RowAction(
            label: 'Add',
            actionKey: 'chart-add',
            icon: Icons.add,
            onTap: () => _editAccount(context, ref),
          ),
        ],
      ],
    );
  }
}

/// Opens the editor for one account, or for a new one.
Future<void> _editAccount(
  BuildContext context,
  WidgetRef ref, [
  Account? existing,
]) async {
  final saved = await showDialog<bool>(
    context: context,
    builder: (_) => _AccountDialog(existing: existing),
  );
  if (saved == true) ref.invalidate(accountsProvider);
}

/// The chart itself, shared by the settings card and the screen.
class _ChartBody extends ConsumerWidget {
  const _ChartBody({this.expanded = false});

  /// Whether the type groups start open.
  final bool expanded;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final accounts = ref.watch(accountsProvider);
    final canEdit = ref.watch(canPostProvider);

    return AsyncView(
      value: accounts,
      onRetry: () => ref.invalidate(accountsProvider),
      // Exactly five, and not a guess: `order` below is a constant, so
      // assets, liabilities, equity, revenue and expense are drawn
      // whatever the chart turns out to hold.
      skeleton: const ListSkeleton(rows: 5, leading: false),
      builder: (list) {
        // Grouped by type, in the order a chart is read: assets,
        // liabilities, equity, revenue, expense. A flat list of a
        // hundred rows is a list nobody scrolls.
        const order = ['asset', 'liability', 'equity', 'revenue', 'expense'];
        return Column(
          children: [
            for (final type in order)
              _TypeGroup(
                type: type,
                accounts: list.where((a) => a.accountType == type).toList(),
                canEdit: canEdit,
                expanded: expanded,
                onEdit: (existing) => _editAccount(context, ref, existing),
              ),
          ],
        );
      },
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
    this.expanded = false,
  });

  final String type;
  final List<Account> accounts;
  final bool canEdit;
  final Future<void> Function(Account?) onEdit;
  final bool expanded;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (accounts.isEmpty) return const SizedBox.shrink();

    return ExpansionTile(
      initiallyExpanded: expanded,
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
            // `0655`. Indented by how deep the number goes, so a
            // chart broken down four levels reads as a shape rather
            // than as a column of increasingly long numbers. The list
            // is in code order, which already puts a child under its
            // parent; this is what makes that visible.
            contentPadding: EdgeInsets.only(
              left: 8 + 16.0 * chartIndentDepth(a.code),
            ),
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
            trailing: canEdit
                ? Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // `0655`. Break an account down: `1120` Bank
                      // accounts, then Maybank and CIMB under it. The
                      // server decides whether this parent may take
                      // one -- it cannot once anything has been posted
                      // to it -- and the dialog asks before it draws a
                      // form, so a refusal is not something somebody
                      // discovers after typing.
                      IconButton(
                        key: ValueKey('sub-account-${a.id}'),
                        tooltip: 'Add a sub-account under this',
                        icon: const Icon(Icons.subdirectory_arrow_right,
                            size: 18),
                        onPressed: a.isActive
                            ? () async {
                                final added = await showSubAccountDialog(
                                  context,
                                  parent: a,
                                );
                                if (added != null) {
                                  ref.invalidate(accountsProvider);
                                }
                              }
                            : null,
                      ),
                      if (!a.isGroup)
                        IconButton(
                          tooltip: 'Retire this account',
                          icon: const Icon(Icons.remove_circle_outline,
                              size: 18),
                          onPressed: a.isActive
                              ? () => _retire(context, ref, a)
                              : null,
                        ),
                    ],
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
          'It is switched off and disappears from the chart, and it '
          'keeps everything ever posted to it. Nothing is deleted — an '
          'account with a balance cannot be, without the books stopping '
          'balancing — and only the operator of this platform can put '
          'it back.',
      confirmLabel: 'Retire',
      destructive: true,
    );
    if (!ok || !context.mounted) return;
    final repo = ref.read(repoProvider);
    if (repo == null) return;

    // One outcome now. 0459 had two — deleted when nothing had ever
    // been posted to it, switched off when something had — and 0619
    // took the delete out: nothing in this product deletes an account
    // any more, so there is no longer anything for the server to
    // decide and nothing to report after the fact.
    await runWithFeedback(
      context,
      doing: 'retire an account',
      action: () => repo.retireAccount(a.id),
      successMessage: '${a.code} is closed, and keeps its history',
    );
    ref.invalidate(accountsProvider);
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
              isExpanded: true,
              initialValue: _type,
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
