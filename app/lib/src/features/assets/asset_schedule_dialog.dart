import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/skeletons.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/models.dart';

/// The fixed asset note, and the history behind any one line of it.
///
/// `docs/unreachable.md` carried this: `depreciation_runs` and
/// `depreciation_entries` were written by the run and never read, so the
/// schedule an auditor asks for by name could not be produced. 0156 adds
/// the two reports; this is what asks for them.
Future<void> showAssetSchedule(BuildContext context) {
  return showDialog<void>(
    context: context,
    builder: (_) => const _ScheduleDialog(),
  );
}

Future<void> showDepreciationHistory(BuildContext context, FixedAsset asset) {
  return showDialog<void>(
    context: context,
    builder: (_) => _HistoryDialog(asset: asset),
  );
}

/// The cast down the note's columns.
///
/// An accountant totals a schedule before believing any line of it, so
/// the totals row is part of the disclosure rather than a convenience.
({
  double costOpening,
  double additions,
  double disposalsCost,
  double costClosing,
  double accumOpening,
  double charge,
  double disposalsAccum,
  double accumClosing,
  double netBookValue,
})
assetScheduleTotals(List<Map<String, dynamic>> rows) {
  double sum(String key) =>
      rows.fold<double>(0, (t, r) => t + Fmt.toDouble(r[key]));
  return (
    costOpening: sum('cost_opening'),
    additions: sum('additions'),
    disposalsCost: sum('disposals_cost'),
    costClosing: sum('cost_closing'),
    accumOpening: sum('accum_opening'),
    charge: sum('charge'),
    disposalsAccum: sum('disposals_accum'),
    accumClosing: sum('accum_closing'),
    netBookValue: sum('net_book_value'),
  );
}

/// Whether the note cross-casts, row by row.
///
/// `supabase/tests/depreciation_schedule.sql` asserts both identities
/// against the database, so this should never fire. It is here because
/// a fixed asset note that does not add up is the one thing a reader
/// must not take on trust, and "the tests cover it" is not something
/// the person holding the printout can check.
///
/// Returns null when everything reconciles.
String? assetScheduleMiscast(List<Map<String, dynamic>> rows) {
  final broken = <String>[];
  for (final r in rows) {
    final costOk =
        (Fmt.toDouble(r['cost_closing']) -
                (Fmt.toDouble(r['cost_opening']) +
                    Fmt.toDouble(r['additions']) -
                    Fmt.toDouble(r['disposals_cost'])))
            .abs() <
        0.005;
    final accumOk =
        (Fmt.toDouble(r['accum_closing']) -
                (Fmt.toDouble(r['accum_opening']) +
                    Fmt.toDouble(r['charge']) -
                    Fmt.toDouble(r['disposals_accum'])))
            .abs() <
        0.005;
    if (!costOk || !accumOk) broken.add(r['category'] as String? ?? '—');
  }
  if (broken.isEmpty) return null;
  return 'This note does not cross-cast under ${broken.join(', ')}. '
      'Brought forward plus additions less disposals should equal carried '
      'forward, and it does not, so do not file it.';
}

class _ScheduleDialog extends ConsumerStatefulWidget {
  const _ScheduleDialog();

  @override
  ConsumerState<_ScheduleDialog> createState() => _ScheduleDialogState();
}

class _ScheduleDialogState extends ConsumerState<_ScheduleDialog> {
  DateTime? _from;
  DateTime? _to;

  Future<void> _pick(bool isFrom) async {
    final picked = await showDatePicker(
      context: context,
      initialDate: (isFrom ? _from : _to) ?? DateTime.now(),
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (picked == null) return;
    setState(() {
      if (isFrom) {
        _from = picked;
      } else {
        _to = picked;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final note = ref.watch(assetMovementsProvider((from: _from, to: _to)));

    return AlertDialog(
      title: const Text('Fixed asset schedule'),
      content: SizedBox(
        width: 900,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Cost and accumulated depreciation by category, with what '
              'came in, what went out and what was charged between the '
              'two dates. Leave the start date empty for the position '
              'since the company began.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: Space.md),
            Row(
              children: [
                Expanded(
                  child: _DateBox(
                    key: const ValueKey('schedule-from'),
                    label: 'From',
                    value: _from,
                    emptyLabel: 'The beginning',
                    onPick: () => _pick(true),
                    onClear: () => setState(() => _from = null),
                  ),
                ),
                const SizedBox(width: Space.sm),
                Expanded(
                  child: _DateBox(
                    key: const ValueKey('schedule-to'),
                    label: 'To',
                    value: _to,
                    emptyLabel: 'Today',
                    onPick: () => _pick(false),
                    onClear: () => setState(() => _to = null),
                  ),
                ),
                const Spacer(),
              ],
            ),
            const SizedBox(height: Space.md),
            Flexible(
              child: AsyncView(
                value: note,
                onRetry: () => ref.invalidate(assetMovementsProvider),
                skeleton: const TableSkeleton(columns: 3, rows: 5),
                builder: (rows) {
                  if (rows.isEmpty) {
                    return const Padding(
                      padding: EdgeInsets.symmetric(vertical: Space.lg),
                      child: Text(
                        'No assets were held in this period, so there is '
                        'no note to make.',
                      ),
                    );
                  }
                  final totals = assetScheduleTotals(rows);
                  final miscast = assetScheduleMiscast(rows);
                  return SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: SizedBox(
                      // The category column plus nine money columns.
                      // Narrower than this and the note wraps mid-figure,
                      // which is why it scrolls sideways rather than
                      // shrinking to fit.
                      width: 150 + 9 * 90,
                      child: SingleChildScrollView(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            const _NoteHeader(),
                            const Divider(height: 1),
                            for (final r in rows) _NoteRow(row: r),
                            const Divider(height: 1),
                            _NoteRow(
                              row: {
                                'category': 'Total',
                                'cost_opening': totals.costOpening,
                                'additions': totals.additions,
                                'disposals_cost': totals.disposalsCost,
                                'cost_closing': totals.costClosing,
                                'accum_opening': totals.accumOpening,
                                'charge': totals.charge,
                                'disposals_accum': totals.disposalsAccum,
                                'accum_closing': totals.accumClosing,
                                'net_book_value': totals.netBookValue,
                              },
                              bold: true,
                            ),
                            if (miscast != null) ...[
                              const SizedBox(height: Space.sm),
                              Text(
                                miscast,
                                key: const ValueKey('schedule-miscast'),
                                style: TextStyle(color: context.colors.danger),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Done'),
        ),
      ],
    );
  }
}

class _NoteHeader extends StatelessWidget {
  const _NoteHeader();

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.labelSmall;
    Widget cell(String text, {double width = 90}) => SizedBox(
      width: width,
      child: Text(text, style: style, textAlign: TextAlign.right),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Space.xs),
      child: Row(
        children: [
          SizedBox(width: 150, child: Text('Category', style: style)),
          cell('Cost b/f'),
          cell('Additions'),
          cell('Disposals'),
          cell('Cost c/f'),
          cell('Depn b/f'),
          cell('Charge'),
          cell('Disposals'),
          cell('Depn c/f'),
          cell('Net book'),
        ],
      ),
    );
  }
}

class _NoteRow extends StatelessWidget {
  const _NoteRow({required this.row, this.bold = false});

  final Map<String, dynamic> row;
  final bool bold;

  @override
  Widget build(BuildContext context) {
    final style = TextStyle(
      fontSize: 12,
      fontWeight: bold ? FontWeight.w700 : null,
    );
    Widget cell(String key, {double width = 90}) => SizedBox(
      width: width,
      child: Text(
        Fmt.plain(Fmt.toDouble(row[key])),
        style: style,
        textAlign: TextAlign.right,
      ),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Space.xs),
      child: Row(
        children: [
          SizedBox(
            width: 150,
            child: Text(row['category'] as String? ?? '—', style: style),
          ),
          cell('cost_opening'),
          cell('additions'),
          cell('disposals_cost'),
          cell('cost_closing'),
          cell('accum_opening'),
          cell('charge'),
          cell('disposals_accum'),
          cell('accum_closing'),
          cell('net_book_value'),
        ],
      ),
    );
  }
}

class _HistoryDialog extends ConsumerWidget {
  const _HistoryDialog({required this.asset});

  final FixedAsset asset;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final history = ref.watch(depreciationHistoryProvider(asset.id));

    return AlertDialog(
      title: Text('${asset.assetNo} · depreciation'),
      content: SizedBox(
        width: 620,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '${asset.name} · ${asset.basis} · cost ${Fmt.money(asset.cost)}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: Space.md),
            Flexible(
              child: AsyncView(
                value: history,
                onRetry: () =>
                    ref.invalidate(depreciationHistoryProvider(asset.id)),
                skeleton: const TableSkeleton(columns: 4, rows: 6),
                builder: (rows) {
                  if (rows.isEmpty) {
                    return const Padding(
                      padding: EdgeInsets.symmetric(vertical: Space.lg),
                      child: Text(
                        'Nothing has been charged against this asset yet. '
                        'Depreciation is posted by a run, and no run has '
                        'reached it.',
                      ),
                    );
                  }
                  return SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [for (final r in rows) _HistoryRow(row: r)],
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Done'),
        ),
      ],
    );
  }
}

class _HistoryRow extends StatelessWidget {
  const _HistoryRow({required this.row});

  final Map<String, dynamic> row;

  @override
  Widget build(BuildContext context) {
    final disposal = row['source'] == 'Disposal';
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      title: Text(
        '${Fmt.date(Fmt.parseDate(row['run_date']))} · ${row['source']}',
        style: TextStyle(
          fontSize: 13,
          fontWeight: disposal ? FontWeight.w600 : null,
        ),
      ),
      subtitle: Text(
        'accumulated ${Fmt.money(Fmt.toDouble(row['opening_accumulated']))} '
        'to ${Fmt.money(Fmt.toDouble(row['closing_accumulated']))}',
        style: const TextStyle(fontSize: 12),
      ),
      trailing: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Money(Fmt.toDouble(row['charge']), bold: true),
          Text(
            'net book ${Fmt.money(Fmt.toDouble(row['net_book_value']))}',
            style: const TextStyle(fontSize: 11),
          ),
        ],
      ),
    );
  }
}

class _DateBox extends StatelessWidget {
  const _DateBox({
    super.key,
    required this.label,
    required this.value,
    required this.emptyLabel,
    required this.onPick,
    required this.onClear,
  });

  final String label;
  final DateTime? value;
  final String emptyLabel;
  final VoidCallback onPick;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    return InputDecorator(
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
        isDense: true,
      ),
      child: Row(
        children: [
          Expanded(
            child: InkWell(
              onTap: onPick,
              child: Text(
                value == null ? emptyLabel : Fmt.date(value),
                style: TextStyle(
                  fontStyle: value == null ? FontStyle.italic : null,
                  color: value == null ? context.scheme.onSurfaceVariant : null,
                ),
              ),
            ),
          ),
          if (value != null)
            InkWell(onTap: onClear, child: const Icon(Icons.close, size: 16)),
        ],
      ),
    );
  }
}
