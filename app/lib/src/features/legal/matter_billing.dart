import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/models.dart';
import '../../data/repository.dart';
import '../secretarial/person_editor.dart' show StatutoryDateField;

/// Which entries `bill_matter_time` would actually bill.
///
/// This mirrors the WHERE clause inside `app.bill_time_internal`
/// deliberately: billable, not already billed, worth something, and
/// inside the period. The function raises when that set is empty, so
/// computing it here is what lets the sheet say "nothing to bill in
/// these dates" instead of offering a button that throws.
///
/// Dates are compared inclusively at both ends because the SQL uses
/// `between`, and a fortnight that silently dropped its last day would
/// leave hours behind for somebody to find months later. Both sides are
/// reduced to the day first: `entry_date` is a `date` in Postgres, but
/// a DateTime parsed on this side can carry a time, and an entry
/// stamped at a quarter to midnight on the last day is still on the
/// last day.
List<TimeEntry> billableInPeriod(
  Iterable<TimeEntry> entries,
  DateTime from,
  DateTime to,
) =>
    entries
        .where((e) =>
            e.isBillable &&
            !e.isBilled &&
            e.amount > 0 &&
            !_day(e.entryDate).isBefore(_day(from)) &&
            !_day(e.entryDate).isAfter(_day(to)))
        .toList();

DateTime _day(DateTime d) => DateTime(d.year, d.month, d.day);

/// What the invoice would come to, rounded to the sen.
double billableTotal(Iterable<TimeEntry> entries) => double.parse(
      entries.fold<double>(0, (a, e) => a + e.amount).toStringAsFixed(2),
    );

/// Hours, from the minutes that were actually recorded.
double billableHours(Iterable<TimeEntry> entries) => double.parse(
      (entries.fold<int>(0, (a, e) => a + e.minutes) / 60).toStringAsFixed(2),
    );

/// A period has to run forwards.
///
/// `bill_time_internal` raises 'The period ends before it starts', and
/// a date picker set by hand is exactly how that happens.
bool periodRunsForward(DateTime from, DateTime to) =>
    !_day(to).isBefore(_day(from));

/// Bill a matter's recorded time.
Future<bool> showBillMatterSheet(
  BuildContext context, {
  required String matterId,
}) async =>
    await showDialog<bool>(
      context: context,
      builder: (_) => _BillMatterSheet(matterId: matterId),
    ) ??
    false;

class _BillMatterSheet extends ConsumerStatefulWidget {
  const _BillMatterSheet({required this.matterId});

  final String matterId;

  @override
  ConsumerState<_BillMatterSheet> createState() => _BillMatterSheetState();
}

class _BillMatterSheetState extends ConsumerState<_BillMatterSheet> {
  late DateTime _from;
  late DateTime _to;
  DateTime? _due;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    // The month just gone, which is what a firm bills at the start of
    // the next one.
    _from = DateTime(now.year, now.month - 1, 1);
    _to = DateTime(now.year, now.month, 0);
  }

  Future<void> _bill(List<TimeEntry> billing) async {
    setState(() => _saving = true);
    final ok = await runWithFeedback(
      context,
      action: () => ref
          .read(repoProvider)!
          .billMatterTime(widget.matterId, _from, _to, dueDate: _due),
      successMessage: 'Invoice raised and posted',
      pendingMessage: 'Billing…',
    );

    if (mounted) setState(() => _saving = false);
    if (ok && mounted) {
      ref.invalidate(timeEntriesProvider(widget.matterId));
      ref.invalidate(documentsProvider);
      ref.invalidate(matterSummaryProvider);
      Navigator.of(context).pop(true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final entries =
        ref.watch(timeEntriesProvider(widget.matterId)).valueOrNull ??
            const <TimeEntry>[];
    final forward = periodRunsForward(_from, _to);
    final billing = forward ? billableInPeriod(entries, _from, _to) : const <TimeEntry>[];
    final total = billableTotal(billing);
    final hours = billableHours(billing);

    // Everything still unbilled, whatever the period. Shown because the
    // usual mistake is a period that misses hours, and a total with
    // nothing to compare it against looks correct.
    final allUnbilled = entries.where((e) => e.isBillable && !e.isBilled);

    return AlertDialog(
      title: const Text('Bill the time recorded'),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(children: [
                Expanded(
                  child: StatutoryDateField(
                    label: 'From',
                    value: _from,
                    enabled: !_saving,
                    onChanged: (d) => setState(() => _from = d ?? _from),
                  ),
                ),
                const SizedBox(width: Space.md),
                Expanded(
                  child: StatutoryDateField(
                    label: 'To',
                    value: _to,
                    enabled: !_saving,
                    onChanged: (d) => setState(() => _to = d ?? _to),
                  ),
                ),
              ]),
              if (!forward)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    'The period ends before it starts.',
                    style: Theme.of(context)
                        .textTheme
                        .bodySmall
                        ?.copyWith(color: context.colors.danger),
                  ),
                ),
              const SizedBox(height: Space.md),
              StatutoryDateField(
                label: 'Due',
                value: _due,
                enabled: !_saving,
                onChanged: (d) => setState(() => _due = d),
              ),
              const SizedBox(height: Space.lg),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(Space.lg),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        billing.isEmpty
                            ? 'Nothing to bill in these dates'
                            : '${billing.length} entries · ${hours}h',
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 4),
                      if (billing.isEmpty)
                        Text(
                          allUnbilled.isEmpty
                              ? 'Every billable hour on this matter has been '
                                  'billed.'
                              : '${billableHours(allUnbilled)}h is unbilled on '
                                  'this matter, all of it outside these dates.',
                          style: Theme.of(context)
                              .textTheme
                              .bodySmall
                              ?.copyWith(color: context.colors.warning),
                        )
                      else ...[
                        Money(total, bold: true),
                        if (billableHours(allUnbilled) > hours)
                          Padding(
                            padding: const EdgeInsets.only(top: 6),
                            child: Text(
                              '${billableHours(allUnbilled)}h unbilled in all, '
                              'so ${(billableHours(allUnbilled) - hours).toStringAsFixed(2)}h '
                              'falls outside these dates.',
                              style: Theme.of(context)
                                  .textTheme
                                  .bodySmall
                                  ?.copyWith(
                                      color: context.scheme.onSurfaceVariant),
                            ),
                          ),
                      ],
                    ],
                  ),
                ),
              ),
              const SizedBox(height: Space.sm),
              Text(
                'Non-billable time and time already billed are left where '
                'they are. An hour cannot be billed twice.',
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: context.scheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('bill-matter'),
          onPressed:
              _saving || billing.isEmpty ? null : () => _bill(billing),
          child: _saving
              ? const SizedBox(
                  height: 16,
                  width: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text('Bill ${Fmt.money(total)}'),
        ),
      ],
    );
  }
}
