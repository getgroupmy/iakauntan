import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/skeletons.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/models.dart';

/// The Schedule 3 working, beside the asset register it comes from.
///
/// ## Why this is not the depreciation schedule with different numbers
///
/// Accounting depreciation is added back in full in a Malaysian tax
/// computation under s.33(1) and replaced by capital allowances at
/// rates Parliament sets. So a laptop depreciated over four years in
/// the accounts is written off at 20% + 20% here, and the two
/// schedules disagreeing is the entire point rather than a
/// discrepancy to reconcile.
///
/// The screen says so out loud, because somebody reading two schedules
/// with different totals will otherwise go looking for the error.
///
/// ## What it does not do
///
/// It does not file anything and it does not compute tax. This is the
/// figure a Form C computation subtracts to get chargeable income; the
/// computation itself is a separate piece of work.
Future<void> showCapitalAllowances(BuildContext context) {
  return showDialog<void>(
    context: context,
    builder: (_) => const _CapitalAllowancesDialog(),
  );
}

class _CapitalAllowancesDialog extends ConsumerStatefulWidget {
  const _CapitalAllowancesDialog();

  @override
  ConsumerState<_CapitalAllowancesDialog> createState() =>
      _CapitalAllowancesDialogState();
}

class _CapitalAllowancesDialogState
    extends ConsumerState<_CapitalAllowancesDialog> {
  /// Last year, not this one.
  ///
  /// A year of assessment is worked on after it has finished. Opening
  /// on the current calendar year would show a schedule nobody is
  /// filing yet, every time.
  late int _year = DateTime.now().year - 1;

  @override
  Widget build(BuildContext context) {
    final rows = ref.watch(capitalAllowancesProvider(_year));
    final scheme = Theme.of(context).colorScheme;
    final now = DateTime.now().year;

    return AlertDialog(
      title: Row(
        children: [
          const Expanded(child: Text('Capital allowances')),
          DropdownButton<int>(
            key: const ValueKey('ca-year'),
            value: _year,
            underline: const SizedBox.shrink(),
            items: [
              // Ten back and one forward. One forward because a company
              // with a non-December year end can be working on a year
              // of assessment the calendar has not finished.
              for (var y = now + 1; y >= now - 10; y--)
                DropdownMenuItem(value: y, child: Text('YA $y')),
            ],
            onChanged: (y) => setState(() => _year = y ?? _year),
          ),
        ],
      ),
      content: SizedBox(
        width: 900,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Schedule 3, ITA 1967. These are not the depreciation '
              'figures and are not meant to agree with them — '
              'depreciation is added back in a tax computation and '
              'replaced by these.',
              style: TextStyle(
                fontSize: 12,
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: Space.md),
            Flexible(
              child: AsyncView(
                value: rows,
                onRetry: () =>
                    ref.invalidate(capitalAllowancesProvider(_year)),
                skeleton: const TableSkeleton(columns: 6, rows: 5),
                builder: (lines) {
                  if (lines.isEmpty) {
                    return const Padding(
                      padding: EdgeInsets.symmetric(vertical: Space.lg),
                      child: Text(
                        'No asset attracted a capital allowance in this '
                        'year. An asset only appears here once it has '
                        'been given a Schedule 3 class — land and '
                        'goodwill never do.',
                      ),
                    );
                  }
                  return _Schedule(lines: lines);
                },
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
      ],
    );
  }
}

class _Schedule extends StatelessWidget {
  const _Schedule({required this.lines});

  final List<CapitalAllowanceLine> lines;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final totals = capitalAllowanceTotals(lines);
    final restricted = lines.where((l) => l.isRestricted).toList();
    final misfiled = lines.where((l) => l.looksMisclassified).toList();

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // An asset filed in a small-value class that is not one gets
          // NOTHING rather than being written off in full — the safe
          // direction, and invisible unless somebody is told. Its
          // residual sitting at the whole cost is the giveaway.
          if (misfiled.isNotEmpty)
            _Notice(
              key: const ValueKey('ca-misfiled'),
              icon: Icons.error_outline,
              colour: scheme.errorContainer,
              onColour: scheme.onErrorContainer,
              text:
                  '${misfiled.length} asset${misfiled.length == 1 ? '' : 's'} '
                  '(${misfiled.map((l) => l.assetNo).join(', ')}) '
                  'attracted nothing at all. A small value class only '
                  'writes off an asset costing less than the threshold; '
                  'above it, put the asset in its ordinary class.',
            ),
          if (restricted.isNotEmpty)
            _Notice(
              key: const ValueKey('ca-restricted'),
              icon: Icons.info_outline,
              colour: scheme.surfaceContainerHighest,
              onColour: scheme.onSurface,
              text:
                  '${restricted.length} '
                  'asset${restricted.length == 1 ? '' : 's'} restricted: '
                  'the allowance is computed on '
                  '${Fmt.money(totals.qualifying)} rather than on what '
                  'was paid. A vehicle above the cap is allowed on the '
                  'cap however much it cost.',
            ),
          if (misfiled.isNotEmpty || restricted.isNotEmpty)
            const SizedBox(height: Space.md),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SizedBox(
              // The asset column plus seven money columns. It scrolls
              // sideways rather than shrinking, because a schedule that
              // wraps mid-figure is a schedule nobody can cast.
              width: 220 + 7 * 96,
              child: DataTable(
                columnSpacing: 12,
                headingRowHeight: 40,
                dataRowMinHeight: 36,
                dataRowMaxHeight: 48,
                columns: const [
                  DataColumn(label: Text('Asset')),
                  DataColumn(label: Text('Cost'), numeric: true),
                  DataColumn(label: Text('Qualifying'), numeric: true),
                  DataColumn(label: Text('Initial'), numeric: true),
                  DataColumn(label: Text('Annual'), numeric: true),
                  DataColumn(label: Text('Balancing'), numeric: true),
                  DataColumn(label: Text('Claimed'), numeric: true),
                  DataColumn(label: Text('Residual'), numeric: true),
                ],
                rows: [
                  for (final l in lines)
                    DataRow(
                      key: ValueKey('ca-row-${l.assetId}'),
                      cells: [
                        DataCell(
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Text(
                                '${l.assetNo} · ${l.name}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              Text(
                                l.classLabel,
                                style: TextStyle(
                                  fontSize: 11,
                                  color: scheme.onSurfaceVariant,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          ),
                        ),
                        DataCell(Text(Fmt.money(l.cost))),
                        DataCell(
                          Text(
                            Fmt.money(l.qualifying),
                            style: l.isRestricted
                                ? TextStyle(color: scheme.error)
                                : null,
                          ),
                        ),
                        DataCell(Text(Fmt.money(l.initial))),
                        DataCell(Text(Fmt.money(l.annual))),
                        // One column for both, because an asset has at
                        // most one of them and two columns of blanks
                        // pushes the figures that matter off the edge.
                        // Signed: a charge is taxable and an allowance
                        // is deductible, so they must not read alike.
                        DataCell(
                          Text(
                            l.balancingCharge > 0
                                ? '(${Fmt.money(l.balancingCharge)})'
                                : l.balancingAllowance > 0
                                ? Fmt.money(l.balancingAllowance)
                                : '',
                            style: l.balancingCharge > 0
                                ? TextStyle(color: scheme.error)
                                : null,
                          ),
                        ),
                        DataCell(Text(Fmt.money(l.claimed))),
                        DataCell(Text(Fmt.money(l.residual))),
                      ],
                    ),
                ],
              ),
            ),
          ),
          const Divider(height: Space.xl),
          // The cast. An accountant totals a schedule before believing a
          // line of it, and these four go to different places on the
          // return — which is why they are four lines and not one.
          _TotalLine(
            label: 'Allowances claimed',
            value: totals.claimed,
            hint: 'Deducted from adjusted income',
          ),
          if (totals.balancingAllowance > 0)
            _TotalLine(
              label: 'Balancing allowance',
              value: totals.balancingAllowance,
              hint: 'Deducted as well',
            ),
          if (totals.balancingCharge > 0)
            _TotalLine(
              label: 'Balancing charge',
              value: totals.balancingCharge,
              hint: 'Added back — this one is taxable',
              emphasis: true,
            ),
          _TotalLine(
            label: 'Residual expenditure carried forward',
            value: totals.residual,
            hint: 'What next year computes from',
          ),
        ],
      ),
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({
    super.key,
    required this.icon,
    required this.colour,
    required this.onColour,
    required this.text,
  });

  final IconData icon;
  final Color colour;
  final Color onColour;
  final String text;

  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.only(bottom: Space.sm),
    padding: const EdgeInsets.all(Space.md),
    decoration: BoxDecoration(
      color: colour,
      borderRadius: BorderRadius.circular(Radii.md),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 18, color: onColour),
        const SizedBox(width: Space.sm),
        Expanded(
          child: Text(
            text,
            style: TextStyle(fontSize: 12, color: onColour),
          ),
        ),
      ],
    ),
  );
}

class _TotalLine extends StatelessWidget {
  const _TotalLine({
    required this.label,
    required this.value,
    required this.hint,
    this.emphasis = false,
  });

  final String label;
  final double value;
  final String hint;
  final bool emphasis;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                Text(
                  hint,
                  style: TextStyle(
                    fontSize: 11,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          Text(
            Fmt.money(value),
            style: TextStyle(
              fontWeight: FontWeight.w600,
              color: emphasis ? scheme.error : null,
            ),
          ),
        ],
      ),
    );
  }
}
