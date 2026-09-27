import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/row_actions.dart';
import '../../core/skeletons.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';

/// What a posted payroll leaves the company owing, and to whom.
///
/// The bank file pays the staff. This is the other half of the same
/// payroll: KWSP, PERKESO twice over, LHDN and HRD Corp, all of them due
/// on the fifteenth of the month following the month the wages were
/// **paid** — a December salary paid on 5 January is remitted by 15
/// February, not 15 January.
///
/// Until 0457 every one of those five liabilities was computed
/// correctly, posted correctly to the ledger, and then never mentioned
/// again.
class StatutoryRemittancesScreen extends ConsumerWidget {
  const StatutoryRemittancesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rows = ref.watch(statutoryRemittancesProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Statutory remittances')),
      body: AsyncView(
        value: rows,
        onRetry: () => ref.invalidate(statutoryRemittancesProvider),
        skeleton: const ListSkeleton(rows: 6, leading: false),
        builder: (list) {
          if (list.isEmpty) {
            return const EmptyState(
              icon: Icons.account_balance_outlined,
              title: 'Nothing owed yet',
              message:
                  'A payroll run has to be posted before what it leaves '
                  'owing is settled. A calculated run is still a figure '
                  'that can change.',
            );
          }

          // Grouped by the month the wages were paid, because that is
          // what a single payment to each body covers.
          final months = <String, List<Map<String, dynamic>>>{};
          for (final r in list) {
            months.putIfAbsent('${r['period_id']}', () => []).add(r);
          }

          return ListView(
            padding: const EdgeInsets.all(Space.lg),
            children: [
              for (final entry in months.entries)
                _MonthCard(rows: entry.value),
            ],
          );
        },
      ),
    );
  }
}

class _MonthCard extends ConsumerWidget {
  const _MonthCard({required this.rows});

  final List<Map<String, dynamic>> rows;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final first = rows.first;
    final paid = DateTime.tryParse('${first['pay_date']}');
    final due = DateTime.tryParse('${first['due_date'] ?? ''}');
    final total = rows.fold<double>(
      0,
      (a, r) => a + ((r['total_amount'] as num?)?.toDouble() ?? 0),
    );
    final anyOverdue = rows.any((r) => r['is_overdue'] == true);

    return Card(
      margin: const EdgeInsets.only(bottom: Space.lg),
      child: Padding(
        padding: const EdgeInsets.all(Space.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SectionHeader(
              '${first['period_code']} · paid ${Fmt.date(paid)}',
              subtitle: due == null
                  ? 'Total ${Fmt.money(total)}'
                  : 'Total ${Fmt.money(total)} · due ${Fmt.date(due)}',
              action: anyOverdue
                  ? Chip(
                      visualDensity: VisualDensity.compact,
                      backgroundColor: context.colors.danger.withValues(
                        alpha: 0.15,
                      ),
                      label: const Text('Overdue'),
                    )
                  : null,
            ),
            for (var i = 0; i < rows.length; i++) ...[
              if (i > 0) const Divider(height: 1),
              _BodyTile(row: rows[i]),
            ],
          ],
        ),
      ),
    );
  }
}

class _BodyTile extends ConsumerWidget {
  const _BodyTile({required this.row});

  final Map<String, dynamic> row;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final canRun = ref.watch(canRunPayrollProvider);
    final paidOn = DateTime.tryParse('${row['paid_on'] ?? ''}');
    final due = DateTime.tryParse('${row['due_date'] ?? ''}');
    final overdue = row['is_overdue'] == true;
    final employee = (row['employee_amount'] as num?)?.toDouble() ?? 0;
    final employer = (row['employer_amount'] as num?)?.toDouble() ?? 0;

    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text('${row['name']}'),
      subtitle: Text(
        [
          '${row['authority']}',
          // Both halves, because the amount to send is the two together
          // and the deducted half on its own is the amount that gets a
          // company short-paid every month.
          if (employee > 0)
            'employee ${Fmt.money(employee)} + employer ${Fmt.money(employer)}',
          if (paidOn != null)
            'sent ${Fmt.date(paidOn)}'
                '${row['reference'] == null ? '' : ' · ${row['reference']}'}'
          else if (due == null)
            'no statutory date — by arrangement'
          else
            'due ${Fmt.date(due)}',
        ].join(' · '),
        style: TextStyle(color: overdue ? context.colors.danger : null),
      ),
      // `RowActions`, so the figure keeps its room. A total plus a
      // labelled "Mark sent" left about 98 pixels for the name of the
      // contribution on a 360px phone, which is not enough for "EPF
      // employee + employer" to read as anything.
      //
      // The tick stays a tick at every width: it is not an action, it
      // is the answer to whether this one has gone, and burying it in
      // a menu would hide the only thing most rows have to say.
      trailing: RowActions(
        menuKey: 'remittance-menu-${row['name']}',
        leading: Padding(
          padding: const EdgeInsets.only(right: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                Fmt.money((row['total_amount'] as num?)?.toDouble() ?? 0),
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              if (paidOn != null) ...[
                const SizedBox(width: 8),
                Icon(
                  Icons.check_circle_outline,
                  size: 18,
                  color: context.colors.success,
                ),
              ],
            ],
          ),
        ),
        actions: [
          if (paidOn == null && canRun)
            RowAction(
              label: 'Mark sent',
              actionKey: 'mark-sent-${row['name']}',
              onTap: () => showDialog<void>(
                context: context,
                builder: (_) => _SendDialog(row: row),
              ),
            ),
        ],
      ),
    );
  }
}

class _SendDialog extends ConsumerStatefulWidget {
  const _SendDialog({required this.row});

  final Map<String, dynamic> row;

  @override
  ConsumerState<_SendDialog> createState() => _SendDialogState();
}

class _SendDialogState extends ConsumerState<_SendDialog> {
  late final TextEditingController _amount = TextEditingController(
    text: ((widget.row['total_amount'] as num?)?.toDouble() ?? 0)
        .toStringAsFixed(2),
  );
  final _reference = TextEditingController();
  DateTime _on = DateTime.now();

  @override
  void dispose() {
    _amount.dispose();
    _reference.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('${widget.row['name']} for ${widget.row['period_code']}'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'This records that the contribution went to '
              '${widget.row['authority']}. It does not send anything — '
              'the submission is made on their portal, and what is kept '
              'here is that it was, for how much, and under what '
              'reference.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _amount,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: const InputDecoration(
                labelText: 'Amount sent',
                prefixText: 'RM ',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _reference,
              decoration: const InputDecoration(
                labelText: 'Reference',
                hintText: 'Optional',
              ),
            ),
            const SizedBox(height: 12),
            InputDatePickerFormField(
              initialDate: _on,
              firstDate: DateTime(2020),
              lastDate: DateTime(2100),
              fieldLabelText: 'Sent on',
              onDateSubmitted: (d) => _on = d,
              onDateSaved: (d) => _on = d,
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
              doing: 'record a statutory remittance',
              successMessage: 'Recorded',
              action: () => repo.recordStatutoryRemittance(
                periodId: widget.row['period_id'] as String,
                code: widget.row['code'] as String,
                amount: double.tryParse(_amount.text.trim()) ?? 0,
                paidOn: _on,
                reference: _reference.text.trim().isEmpty
                    ? null
                    : _reference.text.trim(),
              ),
            );
            ref.invalidate(statutoryRemittancesProvider);
            ref.invalidate(statutoryDueProvider);
            if (done && context.mounted) Navigator.pop(context);
          },
          child: const Text('Record it'),
        ),
      ],
    );
  }
}
