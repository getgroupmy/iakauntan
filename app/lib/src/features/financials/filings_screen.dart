import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/skeletons.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/models.dart';
import '../../data/repository.dart';

/// One row per financial year, newest first.
///
/// The status is the whole story of a filing — draft, frozen, lodged —
/// and it is the only thing on this screen that is not a date, so it
/// carries the colour.
class FilingsScreen extends ConsumerWidget {
  const FilingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final filings = ref.watch(fsFilingsProvider);
    final canWrite = ref.watch(canWriteProvider);
    final canPost = ref.watch(canPostProvider);
    // Asked once for the whole list rather than once per row. It is
    // allowed to fail without taking the screen with it: the list is
    // still the list if the countdown is missing, and `report_fs_deadlines`
    // answers only for a company that holds the MBRS module.
    final due = ref
        .watch(fsDeadlinesDueProvider)
        .maybeWhen(data: (m) => m, orElse: () => const <String, Map<String, dynamic>>{});

    return Scaffold(
      appBar: AppBar(
        title: const Text('Financial statements'),
        actions: [
          // The tax computation is the other half of a year end and
          // has nowhere else to live: it is keyed to a financial year,
          // and this is the screen that lists them.
          if (canPost)
            IconButton(
              key: const ValueKey('open-tax-computation'),
              tooltip: 'Tax computation',
              icon: const Icon(Icons.calculate_outlined),
              onPressed: () => _openTaxComputation(context, ref),
            ),
        ],
      ),
      body: AsyncView(
        value: filings,
        onRetry: () => ref.invalidate(fsFilingsProvider),
        skeleton: const ListSkeleton(rows: 6),
        builder: (list) {
          if (list.isEmpty) {
            return const EmptyState(
              icon: Icons.description_outlined,
              title: 'No accounts prepared yet',
              message:
                  'Start a financial year to map it to the MBRS '
                  'taxonomy and prepare it for lodgement.',
            );
          }
          return ListView.separated(
            itemCount: list.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (context, i) => _FilingTile(
              row: list[i],
              due: due[list[i]['id']?.toString()],
            ),
          );
        },
      ),
      floatingActionButton: canWrite
          ? FloatingActionButton.extended(
              onPressed: () => _newFiling(context, ref),
              icon: const Icon(Icons.add),
              label: const Text('Financial year'),
            )
          : null,
    );
  }

  Future<void> _newFiling(BuildContext context, WidgetRef ref) async {
    final year = await showDialog<({DateTime start, DateTime end})>(
      context: context,
      builder: (_) => const _NewFilingDialog(),
    );
    if (year == null || !context.mounted) return;

    String? id;
    final ok = await runWithFeedback(
      context,
      action: () async {
        id = await ref
            .read(repoProvider)!
            .createFsFiling(fyStart: year.start, fyEnd: year.end);
      },
      successMessage: null,
    );
    ref.invalidate(fsFilingsProvider);
    if (ok && id != null && context.mounted) {
      context.go('/financial-statements/${id!}');
    }
  }
}

class _FilingTile extends StatelessWidget {
  const _FilingTile({required this.row, this.due});

  final Map<String, dynamic> row;

  /// The row `report_fs_deadlines` returned for this filing, or null if
  /// it returned none — which means lodged, or due further out than the
  /// window the provider asks for. Either way there is nothing to count
  /// down to and the tile says nothing.
  final Map<String, dynamic>? due;

  @override
  Widget build(BuildContext context) {
    final status = row['status']?.toString() ?? 'draft';
    final end = Fmt.parseDate(row['fy_end']);
    final audit = row['audit_status']?.toString() ?? 'audited';

    return ListTile(
      leading: Icon(
        switch (status) {
          'lodged' => Icons.verified_outlined,
          'frozen' => Icons.lock_outline,
          _ => Icons.edit_note_outlined,
        },
        color: switch (status) {
          'lodged' => context.colors.success,
          'frozen' => context.colors.info,
          _ => null,
        },
      ),
      title: Text(
        end == null ? 'Financial year' : 'Year ended ${Fmt.date(end)}',
        style: const TextStyle(fontWeight: FontWeight.w600),
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            [
              (row['framework']?.toString() ?? 'mpers').toUpperCase(),
              Fmt.label(audit),
              if (row['mbrs_reference'] != null) '${row['mbrs_reference']}',
            ].join(' · '),
            style: const TextStyle(fontSize: 12),
          ),
          if (due != null) _Countdown(due: due!),
        ],
      ),
      trailing: StatusChip(status),
      onTap: () => context.go('/financial-statements/${row['id']}'),
    );
  }
}

/// The line under a filing, from the row `report_fs_deadlines` returned.
///
/// Null when there is nothing to say: no row, or a row with no
/// `lodge_by` in it. A caller that gets null shows nothing rather than
/// an empty line, because a filing with no deadline is a filing already
/// lodged and saying "Lodge by —" about it would be wrong twice.
///
/// Separated from the widget so the wording can be asserted. The
/// arithmetic behind it is `fs_deadlines`, asserted in
/// `supabase/tests/fs_statutory_order.sql` against hand-worked s.258
/// dates; what is asserted here is only that the right one of the two
/// sentences is chosen, and that "1 day" is not "1 days".
({String text, bool late})? lodgementLine(Map<String, dynamic>? due) {
  if (due == null) return null;
  final by = Fmt.parseDate(due['lodge_by']);
  if (by == null) return null;
  final left = (due['days_left'] as num?)?.toInt();
  final late = due['is_late'] == true;

  // Past tense once the date has gone, because a countdown that has run
  // out is not a countdown. `days_left` goes negative there and saying
  // "-12 days" reads as a bug rather than as a breach.
  if (late) return (text: 'Lodgement was due ${Fmt.date(by)}', late: true);
  if (left == null) return (text: 'Lodge by ${Fmt.date(by)}', late: false);
  if (left == 0) return (text: 'Lodge by ${Fmt.date(by)} — today', late: false);
  return (
    text: 'Lodge by ${Fmt.date(by)} — $left ${left == 1 ? 'day' : 'days'}',
    late: false,
  );
}

/// How long is left to lodge, in the words the deadline is set in.
///
/// CA 2016 s.258 gives six months from the year end to circulate the
/// accounts and thirty days after that to lodge them. `fs_deadlines`
/// does that arithmetic and `report_fs_deadlines` carries it for the
/// whole list; this only says which of the two sentences it is and
/// colours the one that has run out.
///
/// Late is `danger` rather than `warning` because it is not a warning:
/// the date has passed and the company is in breach.
class _Countdown extends StatelessWidget {
  const _Countdown({required this.due});

  final Map<String, dynamic> due;

  @override
  Widget build(BuildContext context) {
    final line = lodgementLine(due);
    if (line == null) return const SizedBox.shrink();
    final late = line.late;
    final text = line.text;

    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            late ? Icons.error_outline : Icons.schedule_outlined,
            size: 13,
            color: late ? context.colors.danger : null,
          ),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              text,
              style: TextStyle(
                fontSize: 12,
                color: late ? context.colors.danger : null,
                fontWeight: late ? FontWeight.w600 : null,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Asking for the year end and deriving the start, rather than asking
/// for both. A financial year that does not run to the day before the
/// next one starts is a data-entry slip, not a choice.
class _NewFilingDialog extends StatefulWidget {
  const _NewFilingDialog();

  @override
  State<_NewFilingDialog> createState() => _NewFilingDialogState();
}

class _NewFilingDialogState extends State<_NewFilingDialog> {
  DateTime _end = DateTime(DateTime.now().year - 1, 12, 31);

  DateTime get _start => DateTime(
    _end.year - 1,
    _end.month,
    _end.day,
  ).add(const Duration(days: 1));

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Which financial year?'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Year end'),
            subtitle: Text(Fmt.date(_end)),
            trailing: const Icon(Icons.calendar_today_outlined, size: 18),
            onTap: () async {
              final picked = await showDatePicker(
                context: context,
                initialDate: _end,
                firstDate: DateTime(2015),
                lastDate: DateTime(2100),
              );
              if (picked != null) setState(() => _end = picked);
            },
          ),
          const SizedBox(height: Space.sm),
          Text(
            'The year will run from ${Fmt.date(_start)}.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, (start: _start, end: _end)),
          child: const Text('Create'),
        ),
      ],
    );
  }
}

/// Which year to compute the tax for, and then its computation.
///
/// A financial year rather than a calendar one, because the basis
/// period is what a year of assessment is taken from -- `0665` derives
/// the year from the period's end date rather than letting anybody
/// type it.
Future<void> _openTaxComputation(BuildContext context, WidgetRef ref) async {
  final years = await ref.read(fiscalYearsProvider.future);
  if (!context.mounted) return;
  if (years.isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'Start a financial year first — a tax computation is for a '
          'basis period.',
        ),
      ),
    );
    return;
  }

  // Newest first: a computation is prepared after the year has ended,
  // so the one somebody wants is almost always the most recent.
  final sorted = [...years]..sort((a, b) => b.endDate.compareTo(a.endDate));

  final chosen = await showDialog<FiscalYear>(
    context: context,
    builder: (ctx) => SimpleDialog(
      title: const Text('Which year?'),
      children: [
        for (final y in sorted)
          SimpleDialogOption(
            key: ValueKey('tax-year-${y.id}'),
            onPressed: () => Navigator.pop(ctx, y),
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text('Year of assessment ${y.endDate.year}'),
              subtitle: Text(
                '${Fmt.date(y.startDate)} to ${Fmt.date(y.endDate)}',
              ),
            ),
          ),
      ],
    ),
  );
  if (chosen == null || !context.mounted) return;

  final repo = ref.read(repoProvider);
  if (repo == null) return;

  String? id;
  final ok = await runWithFeedback(
    context,
    doing: 'open the tax computation',
    successMessage: null,
    action: () async {
      id = await repo.openTaxComputation(chosen.id);
    },
  );
  if (ok && id != null && context.mounted) {
    GoRouter.of(context).push('/tax-computation/$id');
  }
}
