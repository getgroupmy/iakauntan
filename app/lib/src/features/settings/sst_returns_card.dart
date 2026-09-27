import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/error_text.dart';
import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/skeletons.dart';
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
              const _DueAlert(),
              AsyncView(
                value: periods,
                onRetry: () => ref.invalidate(sstTaxablePeriodsProvider),
                skeleton: const ListSkeleton(rows: 4, leading: false),
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

/// The one sentence a company needs before it reads any list: whether a
/// return is late, or how long is left on the next one.
///
/// `report_sst_due` already answers that — it filters to the periods
/// that have ended, have not been filed, and fall due inside the
/// window, in due-date order. Until now nothing drew it: the card
/// listed every period, newest first, and left the reader to work out
/// which of them was a breach. A deadline nobody can see is a deadline
/// nobody meets.
///
/// Null when there is nothing to say — no unfiled return inside the
/// window — so the card shows nothing rather than an empty reassurance.
/// "Everything is filed" would be a claim about periods the window does
/// not cover, and this function cannot make it.
///
/// Separated from the widget so the wording can be asserted. The
/// arithmetic is `sst_taxable_periods` and `report_sst_due`, asserted in
/// `supabase/tests/sst_taxable_period.sql`; what is asserted here is only which
/// sentence is chosen, that "1 day" is not "1 days", and that a missed
/// date is stated in the past tense rather than as a negative countdown.
({String text, bool overdue})? sstDueLine(List<Map<String, dynamic>> rows) {
  if (rows.isEmpty) return null;

  // `report_sst_due` returns them in due-date order, so the first
  // overdue row is the one that has been outstanding longest.
  final late = rows.where((r) => r['is_overdue'] == true).toList();
  if (late.isNotEmpty) {
    final total = late.fold<double>(
      0,
      (sum, r) => sum + Fmt.toDouble(r['output_tax']),
    );
    if (late.length == 1) {
      final r = late.single;
      return (
        text:
            'The return for the period ending '
            '${Fmt.date(Fmt.parseDate(r['period_end']))} was due '
            '${Fmt.date(Fmt.parseDate(r['due_date']))}. '
            '${Fmt.money(total)} was charged in it.',
        overdue: true,
      );
    }
    return (
      text:
          '${late.length} returns are overdue. The earliest was due '
          '${Fmt.date(Fmt.parseDate(late.first['due_date']))}, and '
          '${Fmt.money(total)} was charged across them.',
      overdue: true,
    );
  }

  final next = rows.first;
  final due = Fmt.parseDate(next['due_date']);
  if (due == null) return null;
  final left = (next['days_left'] as num?)?.toInt();
  final tax = Fmt.money(Fmt.toDouble(next['output_tax']));
  final ending = Fmt.date(Fmt.parseDate(next['period_end']));

  // Past tense is the overdue branch's job. Here the date is still
  // ahead, so `days_left` is zero or more and reads as a countdown.
  final when = left == null
      ? 'due ${Fmt.date(due)}'
      : left == 0
      ? 'due today, ${Fmt.date(due)}'
      : 'due ${Fmt.date(due)} — $left ${left == 1 ? 'day' : 'days'}';
  return (
    text: 'The return for the period ending $ending is $when. $tax to declare.',
    overdue: false,
  );
}

/// Draws [sstDueLine] above the list.
///
/// Overdue is `danger` rather than `warning` for the reason the filings
/// countdown uses it: the date has gone and the company is late, which
/// is not a warning about something that might happen.
class _DueAlert extends ConsumerWidget {
  const _DueAlert();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rows = ref.watch(sstDueProvider).valueOrNull;
    // A card that has not loaded yet, or whose load failed, says
    // nothing: the list below carries its own error state, and two
    // failures reported twice is noise.
    if (rows == null) return const SizedBox.shrink();
    final line = sstDueLine(rows);
    if (line == null) return const SizedBox.shrink();

    final colour = line.overdue
        ? context.colors.danger
        : context.colors.warning;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            line.overdue ? Icons.error_outline : Icons.schedule,
            size: 18,
            color: colour,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              line.text,
              key: const ValueKey('sst-due-line'),
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: colour,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
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
            const SizedBox(height: 12),
            // The figure split the way the Act splits it, because the
            // person copying it onto the form needs to know which half
            // is which — and because a service-tax line that looks
            // small for the invoices issued in the period is right,
            // not missing.
            _Breakdown(periodEnd: '${widget.row['period_end']}'),
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

/// What the period's figure is made of.
///
/// Three bases can appear, and they mean different things: sales tax is
/// due when the goods go, service tax when the money comes, and service
/// tax on an invoice that reached twelve months without being paid for
/// falls due anyway. A company that reads only the total will file the
/// right number; a company that reads this will understand why it is
/// not the total of the invoices it issued.
class _Breakdown extends ConsumerWidget {
  const _Breakdown({required this.periodEnd});

  final String periodEnd;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lines = ref.watch(sstReturnLinesProvider(periodEnd));

    return lines.when(
      loading: () => const LinearProgressIndicator(),
      error: (e, _) => Text(errorText(e), style: Theme.of(context).textTheme.bodySmall),
      data: (rows) {
        if (rows.isEmpty) {
          return Text(
            'Nothing fell due in this period.',
            style: Theme.of(context).textTheme.bodySmall,
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final r in rows)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '${r['tax_type_name']} · ${_basis('${r['basis']}')}',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                    Text(
                      Fmt.money((r['tax_amount'] as num?)?.toDouble() ?? 0),
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
          ],
        );
      },
    );
  }

  static String _basis(String code) => switch (code) {
    'payment' => 'on payments received',
    'twelve months' => 'unpaid twelve months on',
    _ => 'on the invoice',
  };
}
