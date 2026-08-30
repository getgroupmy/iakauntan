import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/export_log.dart';
import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/repository.dart';
import 'fs_mapping.dart';
import 'mtool_csv.dart';

/// One set of accounts, from mapping to lodgement.
///
/// The order down the page is the order the work happens in: does it
/// balance, who audited it, when is it due, may it be unaudited at all,
/// and finally what the statements say. Anything that would stop a
/// filing being accepted is above the numbers, not below them.
class FilingScreen extends ConsumerWidget {
  const FilingScreen({super.key, required this.filingId});

  final String filingId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final filing = ref.watch(fsFilingProvider(filingId));

    return Scaffold(
      appBar: AppBar(
        title: const Text('Financial statements'),
        actions: [
          // What the export is built from. `fs_account_map` holds the
          // deviations from the default mapping and nothing could read
          // or write one, so a chart that does not match the default
          // reported wrongly with no remedy in the product.
          IconButton(
            key: const ValueKey('fs-mapping'),
            tooltip: 'How the chart reports',
            icon: const Icon(Icons.account_tree_outlined),
            onPressed: () async {
              if (await showFsMapping(context)) {
                // The statements on this screen are the export, so
                // remapping an account moves what is shown here too.
                ref.invalidate(fsExportProvider(filingId));
              }
            },
          ),
          IconButton(
            tooltip: 'Export for mTool',
            icon: const Icon(Icons.download_outlined),
            onPressed: () => _export(context, ref),
          ),
        ],
      ),
      body: AsyncView(
        value: filing,
        onRetry: () => ref.invalidate(fsFilingProvider(filingId)),
        builder: (f) {
          if (f == null) {
            return const EmptyState(
              icon: Icons.help_outline,
              title: 'Not found',
              message: 'These accounts no longer exist.',
            );
          }
          final status = f['status']?.toString() ?? 'draft';

          return ListView(
            padding: const EdgeInsets.all(Space.lg),
            children: [
              _MbrsBanner(status: status, reference: f['mbrs_reference']),
              const SizedBox(height: Space.lg),
              _BalanceCard(filingId: filingId),
              const SizedBox(height: Space.lg),
              _DeadlineCard(filingId: filingId),
              const SizedBox(height: Space.lg),
              _ExemptionCard(
                filingId: filingId,
                auditStatus: f['audit_status'],
              ),
              const SizedBox(height: Space.lg),
              _Actions(filing: f),
              const SizedBox(height: Space.lg),
              _Statements(filingId: filingId),
            ],
          );
        },
      ),
    );
  }

  Future<void> _export(BuildContext context, WidgetRef ref) async {
    final rows = await ref.read(fsExportProvider(filingId).future);
    if (!context.mounted) return;
    if (rows.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Nothing to export yet.')));
      return;
    }

    final saved = await exportTextFile(
      ref,
      mtoolFilename(rows),
      'text/csv',
      mtoolCsv(rows),
      what: 'MBRS mTool export',
      detail: '${rows.length} lines',
    );
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          saved
              ? 'Exported. Import it into mTool, then upload from mPortal.'
              : 'Export is only available in the browser.',
        ),
      ),
    );
  }
}

/// Said once, plainly, at the top.
///
/// The temptation is to leave this out because the team knows. The team
/// changes, and a screen with a "Lodge" button on it that never says
/// where the lodging happens is a screen somebody will assume filed
/// their client's accounts.
class _MbrsBanner extends StatelessWidget {
  const _MbrsBanner({required this.status, this.reference});

  final String status;
  final Object? reference;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Space.lg),
        child: Row(
          children: [
            Icon(Icons.info_outline, size: 20, color: context.colors.info),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(switch (status) {
                    'lodged' => 'Lodged — reference ${reference ?? ''}',
                    'frozen' => 'Frozen, ready to export',
                    _ => 'Draft — the figures still move with the ledger',
                  }, style: const TextStyle(fontWeight: FontWeight.w600)),
                  Text(
                    'iAkauntan does not submit to SSM. Export these figures, '
                    'import them into mTool, and upload the file it '
                    'generates through mPortal — then record the reference '
                    'here.',
                    style: Theme.of(context).textTheme.bodySmall,
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

class _BalanceCard extends ConsumerWidget {
  const _BalanceCard({required this.filingId});

  final String filingId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final check = ref.watch(fsBalanceCheckProvider(filingId));

    return check.when(
      loading: () =>
          const Card(child: ListTile(title: Text('Checking the statements…'))),
      error: (e, _) => Card(child: ListTile(title: Text('$e'))),
      data: (r) {
        if (r == null) return const SizedBox.shrink();
        final balances = r['balances'] == true;
        final diff = r['difference'] as num? ?? 0;

        return Card(
          color: balances
              ? null
              : context.colors.danger.withValues(alpha: 0.08),
          child: Padding(
            padding: const EdgeInsets.all(Space.lg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      balances
                          ? Icons.check_circle_outline
                          : Icons.error_outline,
                      size: 20,
                      color: balances
                          ? context.colors.success
                          : context.colors.danger,
                    ),
                    const SizedBox(width: 12),
                    Text(
                      balances
                          ? 'The statement of financial position balances'
                          : 'Out by ${Fmt.money(diff)}',
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ],
                ),
                const SizedBox(height: Space.sm),
                Text(
                  'Assets ${Fmt.money(r['assets'] as num? ?? 0)} · '
                  'Liabilities ${Fmt.money(r['liabilities'] as num? ?? 0)} · '
                  'Equity ${Fmt.money(r['equity'] as num? ?? 0)}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _DeadlineCard extends ConsumerWidget {
  const _DeadlineCard({required this.filingId});

  final String filingId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final due = ref.watch(fsDeadlinesProvider(filingId)).valueOrNull;
    if (due == null) return const SizedBox.shrink();

    final late = due['is_late'] == true;
    final circulate = Fmt.parseDate(due['circulate_by']);
    final lodge = Fmt.parseDate(due['lodge_by']);
    final lodged = Fmt.parseDate(due['lodged_on']);

    return Card(
      color: late ? context.colors.danger.withValues(alpha: 0.08) : null,
      child: Padding(
        padding: const EdgeInsets.all(Space.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              lodged != null
                  ? 'Lodged ${Fmt.date(lodged)}'
                  : late
                  ? 'Overdue'
                  : 'Due in ${due['days_left']} days',
              style: TextStyle(
                fontWeight: FontWeight.w600,
                color: late ? context.colors.danger : null,
              ),
            ),
            const SizedBox(height: Space.sm),
            Text(
              'Circulate by ${circulate == null ? '—' : Fmt.date(circulate)} · '
              'lodge by ${lodge == null ? '—' : Fmt.date(lodge)}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: Space.xs),
            Text(
              due['basis']?.toString() ?? '',
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(fontStyle: FontStyle.italic),
            ),
          ],
        ),
      ),
    );
  }
}

/// All three grounds, including the ones that do not apply.
///
/// Showing only the ground that succeeds would answer "am I exempt" and
/// leave "why not" — which is the question somebody has when they
/// expected to be — to guesswork.
class _ExemptionCard extends ConsumerWidget {
  const _ExemptionCard({required this.filingId, this.auditStatus});

  final String filingId;
  final Object? auditStatus;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final grounds = ref.watch(fsExemptionProvider(filingId)).valueOrNull;
    if (grounds == null || grounds.isEmpty) return const SizedBox.shrink();

    final any = grounds.any((g) => g['qualifies'] == true);
    final claimed = auditStatus == 'audit_exempt';

    return Card(
      // The dangerous combination is claiming exemption without a ground
      // for it: that is filing unaudited accounts that needed an audit.
      color: claimed && !any
          ? context.colors.danger.withValues(alpha: 0.08)
          : null,
      child: Padding(
        padding: const EdgeInsets.all(Space.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              claimed && !any
                  ? 'Exemption claimed, but no ground applies'
                  : any
                  ? 'Audit exemption available'
                  : 'An audit is required',
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: Space.xs),
            Text(
              'Practice Directive 3/2018, tested over this financial year '
              'and the two before it.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: Space.md),
            for (final g in grounds)
              Padding(
                padding: const EdgeInsets.only(bottom: Space.sm),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      g['qualifies'] == true
                          ? Icons.check_circle_outline
                          : Icons.remove_circle_outline,
                      size: 16,
                      color: g['qualifies'] == true
                          ? context.colors.success
                          : Theme.of(context).disabledColor,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            Fmt.label(g['ground']?.toString() ?? ''),
                            style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          Text(
                            g['reason']?.toString() ?? '',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                      ),
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

class _Actions extends ConsumerWidget {
  const _Actions({required this.filing});

  final Map<String, dynamic> filing;

  String get _id => filing['id'] as String;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = filing['status']?.toString() ?? 'draft';
    final canWrite = ref.watch(canWriteProvider);
    final canAdmin = ref.watch(canAdminProvider);
    if (!canWrite) return const SizedBox.shrink();

    return Wrap(
      spacing: Space.sm,
      runSpacing: Space.sm,
      children: [
        if (status == 'draft')
          FilledButton.icon(
            onPressed: () => _freeze(context, ref),
            icon: const Icon(Icons.lock_outline, size: 18),
            label: const Text('Freeze the figures'),
          ),
        if (status == 'frozen') ...[
          FilledButton.icon(
            onPressed: () => _lodge(context, ref),
            icon: const Icon(Icons.upload_file_outlined, size: 18),
            label: const Text('Record lodgement'),
          ),
          if (canAdmin)
            OutlinedButton.icon(
              onPressed: () => _unfreeze(context, ref),
              icon: const Icon(Icons.lock_open_outlined, size: 18),
              label: const Text('Reopen'),
            ),
        ],
      ],
    );
  }

  void _refresh(WidgetRef ref) {
    ref.invalidate(fsFilingProvider(_id));
    ref.invalidate(fsExportProvider(_id));
    ref.invalidate(fsBalanceCheckProvider(_id));
    ref.invalidate(fsFilingsProvider);
  }

  Future<void> _freeze(BuildContext context, WidgetRef ref) async {
    final ok = await confirm(
      context,
      title: 'Freeze these figures?',
      message:
          'The accounts stop following the ledger. A journal posted '
          'into this year afterwards will not change what was filed — '
          'which is the point, and why an administrator has to reopen '
          'them to change anything.',
      confirmLabel: 'Freeze',
    );
    if (!ok || !context.mounted) return;

    await runWithFeedback(
      context,
      action: () => ref.read(repoProvider)!.fsFreeze(_id),
      successMessage: 'Frozen',
    );
    _refresh(ref);
  }

  Future<void> _unfreeze(BuildContext context, WidgetRef ref) async {
    final ok = await confirm(
      context,
      title: 'Reopen these accounts?',
      message:
          'The figures start following the ledger again and the '
          'frozen set is discarded.',
      confirmLabel: 'Reopen',
      destructive: true,
    );
    if (!ok || !context.mounted) return;

    await runWithFeedback(
      context,
      action: () => ref.read(repoProvider)!.fsUnfreeze(_id),
      successMessage: 'Reopened',
    );
    _refresh(ref);
  }

  Future<void> _lodge(BuildContext context, WidgetRef ref) async {
    final reference = await showDialog<String>(
      context: context,
      builder: (_) => const _LodgeDialog(),
    );
    if (reference == null || !context.mounted) return;

    await runWithFeedback(
      context,
      action: () => ref.read(repoProvider)!.fsLodge(_id, reference: reference),
      successMessage: 'Lodgement recorded',
    );
    _refresh(ref);
  }
}

class _LodgeDialog extends StatefulWidget {
  const _LodgeDialog();

  @override
  State<_LodgeDialog> createState() => _LodgeDialogState();
}

class _LodgeDialogState extends State<_LodgeDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Record the lodgement'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'The reference mPortal gave you after the upload. This is the '
            'only evidence here that a filing happened.',
          ),
          const SizedBox(height: Space.md),
          TextField(
            controller: _controller,
            autofocus: true,
            decoration: const InputDecoration(labelText: 'MBRS reference'),
            onChanged: (_) => setState(() {}),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _controller.text.trim().isEmpty
              ? null
              : () => Navigator.pop(context, _controller.text.trim()),
          child: const Text('Record'),
        ),
      ],
    );
  }
}

class _Statements extends ConsumerWidget {
  const _Statements({required this.filingId});

  final String filingId;

  static const _titles = {
    'sofp': 'Statement of financial position',
    'soploci': 'Profit or loss and other comprehensive income',
    'socie': 'Changes in equity',
    'socf': 'Cash flows',
    'disclosure': 'Disclosures',
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rows = ref.watch(fsExportProvider(filingId));

    return AsyncView(
      value: rows,
      onRetry: () => ref.invalidate(fsExportProvider(filingId)),
      builder: (list) {
        if (list.isEmpty) {
          return const EmptyState(
            icon: Icons.calculate_outlined,
            title: 'Nothing posted in this year',
            message:
                'The statements are built from the ledger. Post some '
                'transactions into this financial year first.',
          );
        }

        final byStatement = <String, List<Map<String, dynamic>>>{};
        for (final r in list) {
          byStatement
              .putIfAbsent(r['statement']?.toString() ?? '', () => [])
              .add(r);
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final entry in byStatement.entries) ...[
              Padding(
                padding: const EdgeInsets.only(top: Space.lg, bottom: Space.sm),
                child: Text(
                  _titles[entry.key] ?? entry.key,
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ),
              Card(
                child: Column(
                  children: [
                    for (final r in entry.value)
                      ListTile(
                        dense: true,
                        title: Text(r['label']?.toString() ?? ''),
                        subtitle: Text(
                          r['element_code']?.toString() ?? '',
                          style: const TextStyle(fontSize: 11),
                        ),
                        trailing: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Money(r['current_amount'] as num?, bold: true),
                            Text(
                              Fmt.money(r['prior_amount'] as num? ?? 0),
                              style: TextStyle(
                                fontSize: 11,
                                color: Theme.of(context).hintColor,
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ],
        );
      },
    );
  }
}
