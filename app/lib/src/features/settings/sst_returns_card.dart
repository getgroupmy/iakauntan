import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';

/// The SST-02 calendar: which taxable period a company is in, what was
/// charged in each, when the return is due and whether it went in.
///
/// Before this the app offered a summary over any two dates somebody
/// typed. That is right for a report and wrong for a return: the period
/// is two calendar months on a cycle fixed by the registration date, and
/// nobody keeps that rhythm in their head. Every other statutory date in
/// this system — SSM, LHDN, the financial statements — is arithmetic
/// rather than something the user remembers, and this was the one that
/// was not.
///
/// Draws nothing at all for a company that is not registered.
class SstReturnsCard extends ConsumerWidget {
  const SstReturnsCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final org = ref.watch(currentOrgProvider).valueOrNull;
    if (org == null || !org.isSstRegistered) return const SizedBox.shrink();

    final periods = ref.watch(sstTaxablePeriodsProvider);
    final canPost = ref.watch(canPostProvider);

    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(Space.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SectionHeader(
                'SST returns',
                subtitle:
                    'Two calendar months, and the return due on the last '
                    'day of the month after',
              ),
              AsyncView(
                value: periods,
                onRetry: () => ref.invalidate(sstTaxablePeriodsProvider),
                builder: (rows) {
                  if (rows.isEmpty) {
                    return Text(
                      'No taxable period has begun yet.',
                      style: Theme.of(context).textTheme.bodySmall,
                    );
                  }
                  // Newest first: the period somebody is about to file is
                  // the one they came here for.
                  final ordered = rows.reversed.toList();
                  return Column(
                    children: [
                      for (var i = 0; i < ordered.length; i++) ...[
                        if (i > 0) const Divider(height: 1),
                        _PeriodTile(row: ordered[i], canPost: canPost),
                      ],
                    ],
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PeriodTile extends ConsumerWidget {
  const _PeriodTile({required this.row, required this.canPost});

  final Map<String, dynamic> row;
  final bool canPost;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final start = DateTime.tryParse('${row['period_start']}');
    final end = DateTime.tryParse('${row['period_end']}');
    final due = DateTime.tryParse('${row['due_date']}');
    final filed = DateTime.tryParse('${row['filed_at'] ?? ''}');
    final tax = (row['output_tax'] as num?)?.toDouble() ?? 0;
    final ended = end != null && end.isBefore(DateTime.now());
    final overdue =
        filed == null && ended && due != null && due.isBefore(DateTime.now());

    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text('${Fmt.date(start)} — ${Fmt.date(end)}'),
      subtitle: Text(
        [
          'Tax charged ${Fmt.money(tax)}',
          if (filed != null)
            'filed ${Fmt.date(filed)}'
                '${row['reference'] == null ? '' : ' · ${row['reference']}'}'
          else if (!ended)
            'in progress'
          else
            'due ${Fmt.date(due)}',
        ].join(' · '),
        style: TextStyle(
          color: overdue ? context.colors.danger : null,
          fontWeight: overdue ? FontWeight.w600 : null,
        ),
      ),
      trailing: filed != null
          ? Icon(
              Icons.check_circle_outline,
              size: 18,
              color: context.colors.success,
            )
          // A period still running has nothing to declare yet, and the
          // database refuses a return for it — so the button is not
          // offered rather than offered and refused.
          : (canPost && ended)
          ? TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => _FileDialog(row: row),
              ),
              child: const Text('Mark filed'),
            )
          : null,
    );
  }
}

class _FileDialog extends ConsumerStatefulWidget {
  const _FileDialog({required this.row});

  final Map<String, dynamic> row;

  @override
  ConsumerState<_FileDialog> createState() => _FileDialogState();
}

class _FileDialogState extends ConsumerState<_FileDialog> {
  late final TextEditingController _amount = TextEditingController(
    text: ((widget.row['output_tax'] as num?)?.toDouble() ?? 0).toStringAsFixed(
      2,
    ),
  );
  final _reference = TextEditingController();

  @override
  void dispose() {
    _amount.dispose();
    _reference.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final end = DateTime.tryParse('${widget.row['period_end']}');

    return AlertDialog(
      title: Text('Return for the period ending ${Fmt.date(end)}'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'This records that the return went in. It does not send '
              'anything to the Customs Department — the SST-02 is filed '
              'on MyTax, and what is kept here is that it was, for how '
              'much, and under what reference.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _amount,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: const InputDecoration(
                labelText: 'Tax declared',
                prefixText: 'RM ',
                helperText:
                    'Pre-filled from what was charged in the period. '
                    'Change it if the return said something else.',
                helperMaxLines: 2,
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
            if (end == null) return;
            final repo = ref.read(repoProvider);
            if (repo == null) return;
            final done = await runWithFeedback(
              context,
              doing: 'record an SST return',
              successMessage: 'Recorded',
              action: () => repo.fileSstReturn(
                periodEnd: end,
                amount: double.tryParse(_amount.text.trim()) ?? 0,
                reference: _reference.text.trim().isEmpty
                    ? null
                    : _reference.text.trim(),
              ),
            );
            ref.invalidate(sstTaxablePeriodsProvider);
            ref.invalidate(sstDueProvider);
            if (done && context.mounted) Navigator.pop(context);
          },
          child: const Text('Record it'),
        ),
      ],
    );
  }
}
