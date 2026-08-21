import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';

/// How the whole company is doing today.
///
/// Every other POS screen takes an outlet and answers about that
/// outlet, which is right for the person standing in it and useless to
/// the person who owns three. This is the missing view: one row per
/// shop, ranked by what they have taken.
///
/// ## Two clocks, labelled as two clocks
///
/// Everything on a row is about the day named except "open", which is
/// about this moment — a parked bill has no day yet. `pos_day_board`
/// returns them as separate columns for that reason and this screen
/// keeps them visibly apart, because a number that quietly means a
/// different clock from the one beside it is worse than no number.
///
/// ## Cash has its own column
///
/// Gross is what was sold; cash is what should be in the drawer. An
/// owner comparing shops is usually comparing that.
class TakingsScreen extends ConsumerStatefulWidget {
  const TakingsScreen({super.key});

  @override
  ConsumerState<TakingsScreen> createState() => _TakingsScreenState();
}

class _TakingsScreenState extends ConsumerState<TakingsScreen> {
  late DateTime _day = _today();

  static DateTime _today() {
    final n = DateTime.now();
    return DateTime(n.year, n.month, n.day);
  }

  @override
  Widget build(BuildContext context) {
    if (!moduleEnabled(ref, 'pos')) {
      return Scaffold(
        appBar: AppBar(title: const Text('Takings')),
        body: const EmptyState(
          icon: Icons.point_of_sale_outlined,
          title: 'The till is not switched on',
          message: 'Takings are what a till took, and this company has none.',
        ),
      );
    }

    final board = ref.watch(posDayBoardProvider(_day));
    final today = _today();
    final isToday = _day == today;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Takings'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh, size: 20),
            onPressed: () => ref.invalidate(posDayBoardProvider(_day)),
          ),
          const SizedBox(width: Space.sm),
        ],
      ),
      body: Column(
        children: [
          // `FilterBar` scrolls horizontally, so nothing in it may ask
          // for the remaining width — there is none to remain.
          FilterBar(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  tooltip: 'The day before',
                  icon: const Icon(Icons.chevron_left),
                  onPressed: () => setState(
                    () => _day = _day.subtract(const Duration(days: 1)),
                  ),
                ),
                SizedBox(
                  width: 160,
                  child: Center(
                    child: Text(
                      isToday ? 'Today' : Fmt.date(_day),
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'The day after',
                  // A shop cannot have taken anything tomorrow, so the
                  // arrow stops rather than showing a page of noughts.
                  icon: const Icon(Icons.chevron_right),
                  onPressed: isToday
                      ? null
                      : () => setState(
                          () => _day = _day.add(const Duration(days: 1)),
                        ),
                ),
              ],
            ),
          ),
          Expanded(
            child: AsyncView(
              value: board,
              onRetry: () => ref.invalidate(posDayBoardProvider(_day)),
              builder: (rows) {
                if (rows.isEmpty) {
                  return const EmptyState(
                    icon: Icons.storefront_outlined,
                    title: 'No outlets',
                    message: 'Set a shop up before expecting it to take money.',
                  );
                }
                final gross = rows.fold<double>(
                  0,
                  (t, r) => t + Fmt.toDouble(r['gross']),
                );
                final bills = rows.fold<int>(
                  0,
                  (t, r) => t + ((r['bills'] as num?)?.toInt() ?? 0),
                );
                final open = rows.fold<int>(
                  0,
                  (t, r) => t + ((r['open_bills'] as num?)?.toInt() ?? 0),
                );

                return ListView(
                  padding: const EdgeInsets.all(Space.lg),
                  children: [
                    _Total(gross: gross, bills: bills, open: open),
                    const SizedBox(height: Space.md),
                    for (final r in rows) _OutletRow(row: r),
                    const SizedBox(height: Space.lg),
                    Text(
                      'Sent to you each morning if an address is set under '
                      'Settings · Email.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _Total extends StatelessWidget {
  const _Total({required this.gross, required this.bills, required this.open});

  final double gross;
  final int bills;
  final int open;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Space.lg),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Everything, everywhere',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: Space.xs),
                  Money(gross, bold: true),
                  Text(
                    '$bills bill${bills == 1 ? '' : 's'}',
                    style: const TextStyle(fontSize: 12),
                  ),
                ],
              ),
            ),
            // Not folded into the total: these are open now, on a
            // different clock from everything beside them.
            if (open > 0)
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    'Open right now',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: Space.xs),
                  Text(
                    '$open',
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w600,
                      color: context.colors.warning,
                    ),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

class _OutletRow extends StatelessWidget {
  const _OutletRow({required this.row});

  final Map<String, dynamic> row;

  @override
  Widget build(BuildContext context) {
    final bills = (row['bills'] as num?)?.toInt() ?? 0;
    final open = (row['open_bills'] as num?)?.toInt() ?? 0;
    final voided = (row['voided_bills'] as num?)?.toInt() ?? 0;

    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(
        '${row['outlet_name']}',
        style: const TextStyle(fontWeight: FontWeight.w500),
      ),
      subtitle: Text(
        [
          '$bills bill${bills == 1 ? '' : 's'}',
          if (bills > 0) 'avg ${Fmt.money(Fmt.toDouble(row['average_bill']))}',
          'cash ${Fmt.money(Fmt.toDouble(row['cash']))}',
          if (Fmt.toDouble(row['non_cash']) > 0)
            'card and wallet ${Fmt.money(Fmt.toDouble(row['non_cash']))}',
          if (open > 0) '$open still open',
          if (voided > 0)
            '$voided written off (${Fmt.money(Fmt.toDouble(row['voided_value']))})',
        ].join(' · '),
        style: TextStyle(
          fontSize: 12,
          // The one thing on the row worth a colour: money that was
          // rung up and then made to go away.
          color: voided > 0 ? context.colors.warning : null,
        ),
      ),
      trailing: Money(Fmt.toDouble(row['gross']), bold: true),
    );
  }
}
