import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/models.dart';

/// The general ledger, as journals.
///
/// Everything posts through `create_gl_entry`, so this is the one screen
/// where an invoice, a payroll run and a hand-written correction can be
/// compared side by side — and, until now, there was no way to look at a
/// journal at all.
class JournalsScreen extends ConsumerWidget {
  const JournalsScreen({super.key});

  static const _sources = <String, String>{
    'sales_invoice': 'Sales invoices',
    'purchase_bill': 'Bills',
    'receipt': 'Receipts',
    'payment': 'Payments',
    'payroll': 'Payroll',
    'stock_movement': 'Stock',
    'recurring': 'Recurring',
    'manual': 'Manual',
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final journals = ref.watch(journalsProvider);
    final filter = ref.watch(journalSourceFilterProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Journals')),
      body: Column(
        children: [
          SizedBox(
            height: 56,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: Space.lg),
              children: [
                Padding(
                  padding: const EdgeInsets.only(right: Space.sm, top: Space.md),
                  child: FilterChip(
                    label: const Text('All'),
                    selected: filter == null,
                    onSelected: (_) => ref
                        .read(journalSourceFilterProvider.notifier)
                        .state = null,
                  ),
                ),
                for (final e in _sources.entries)
                  Padding(
                    padding:
                        const EdgeInsets.only(right: Space.sm, top: Space.md),
                    child: FilterChip(
                      label: Text(e.value),
                      selected: filter == e.key,
                      onSelected: (on) => ref
                          .read(journalSourceFilterProvider.notifier)
                          .state = on ? e.key : null,
                    ),
                  ),
              ],
            ),
          ),
          Expanded(
            child: AsyncView(
              value: journals,
              onRetry: () => ref.invalidate(journalsProvider),
              builder: (list) => list.isEmpty
                  ? const EmptyState(
                      icon: Icons.menu_book_outlined,
                      title: 'No journals',
                      message: 'Every posted document writes one. Post an '
                          'invoice, a bill or a payroll run and it appears '
                          'here.',
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.only(bottom: Space.xxl),
                      itemCount: list.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (_, i) => _JournalTile(entry: list[i]),
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

class _JournalTile extends ConsumerWidget {
  const _JournalTile({required this.entry});

  final JournalEntry entry;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final canPost = ref.watch(canPostProvider);
    final muted = Theme.of(context)
        .textTheme
        .bodySmall
        ?.copyWith(color: context.scheme.onSurfaceVariant);

    return ExpansionTile(
      tilePadding: const EdgeInsets.symmetric(horizontal: Space.lg),
      childrenPadding: const EdgeInsets.fromLTRB(
          Space.lg, 0, Space.lg, Space.lg),
      title: Row(children: [
        Flexible(
          child: Text(
            entry.entryNo,
            style: TextStyle(
              fontWeight: FontWeight.w600,
              // A voided journal is still in the ledger and still adds
              // up; it just no longer counts.
              decoration: entry.isVoid ? TextDecoration.lineThrough : null,
            ),
          ),
        ),
        const SizedBox(width: Space.sm),
        StatusChip(entry.status, compact: true),
        if (entry.isReversal) ...[
          const SizedBox(width: Space.xs),
          const StatusChip('reversal', compact: true),
        ],
      ]),
      subtitle: Text(
        '${Fmt.date(entry.entryDate)} · ${Fmt.label(entry.source)}'
        '${entry.description == null ? '' : ' · ${entry.description}'}',
        style: const TextStyle(fontSize: 12),
      ),
      trailing: Money(entry.totalDebit, bold: true),
      children: [
        for (final l in entry.lines)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(children: [
              SizedBox(width: 64, child: Text(l.accountCode, style: muted)),
              Expanded(
                flex: 3,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(l.accountName),
                    if (l.description != null && l.description!.isNotEmpty)
                      Text(l.description!, style: muted),
                  ],
                ),
              ),
              Expanded(child: l.debit == 0 ? const SizedBox() : Money(l.debit)),
              Expanded(
                  child: l.credit == 0 ? const SizedBox() : Money(l.credit)),
            ]),
          ),
        const Divider(),
        Row(children: [
          const Expanded(flex: 3, child: SizedBox()),
          Expanded(child: Money(entry.totalDebit, bold: true)),
          Expanded(child: Money(entry.totalCredit, bold: true)),
        ]),
        if (canPost && entry.canReverse) ...[
          const SizedBox(height: Space.md),
          Align(
            alignment: Alignment.centerRight,
            child: OutlinedButton.icon(
              onPressed: () => _reverse(context, ref),
              icon: const Icon(Icons.undo, size: 18),
              label: const Text('Reverse'),
            ),
          ),
        ],
      ],
    );
  }

  Future<void> _reverse(BuildContext context, WidgetRef ref) async {
    final on = await showDatePicker(
      context: context,
      initialDate: DateTime.now(),
      firstDate: DateTime(entry.entryDate.year - 1),
      lastDate: DateTime(DateTime.now().year + 1, 12, 31),
      helpText: 'Date the reversal posts',
    );
    if (on == null || !context.mounted) return;

    final ok = await confirm(
      context,
      title: 'Reverse ${entry.entryNo}?',
      message: 'This posts the mirror image on ${Fmt.date(on)} and marks the '
          'original void. Nothing is deleted — a ledger you can erase is '
          'not a ledger.',
      confirmLabel: 'Reverse',
    );
    if (!ok || !context.mounted) return;

    await runWithFeedback(
      context,
      action: () => ref.read(repoProvider)!.reverseJournal(entry.id, on),
      successMessage: 'Reversed',
    );
    ref.invalidate(journalsProvider);
    refreshLedgerData(ref);
  }
}
