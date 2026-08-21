import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';

/// What went off the bills, and why.
///
/// 0225 wrote `pos_void_summary` for "the screen a manager opens when
/// the food cost does not match the takings", and nothing ever opened
/// it. Voids are where a till leaks: a line taken off after the kitchen
/// has cooked it is either waste, a mistake, or somebody helping
/// themselves, and the three look identical in the day's takings.
///
/// ## Grouped, because one void is not the point
///
/// The function returns one row per reason rather than a list of
/// incidents, and that is the whole design: one void is an accident,
/// and thirty "not received" in a week is a conversation with somebody.
/// A screen that listed every void would bury the pattern in the
/// evidence.
///
/// ## The day is the shop's day
///
/// `pos_void_summary` works in Asia/Kuala_Lumpur, so a sale rung up at
/// eleven at night falls on the day the shop thinks it does rather than
/// on whatever UTC says. The dates sent up are plain dates for that
/// reason, and nothing here converts a timezone.
class VoidsScreen extends ConsumerStatefulWidget {
  const VoidsScreen({super.key});

  @override
  ConsumerState<VoidsScreen> createState() => _VoidsScreenState();
}

class _VoidsScreenState extends ConsumerState<VoidsScreen> {
  late ({DateTime from, DateTime to}) _range = _lastDays(7);

  static ({DateTime from, DateTime to}) _lastDays(int days) {
    final now = DateTime.now();
    final to = DateTime(now.year, now.month, now.day);
    return (from: to.subtract(Duration(days: days - 1)), to: to);
  }

  @override
  Widget build(BuildContext context) {
    if (!moduleEnabled(ref, 'pos')) {
      return Scaffold(
        appBar: AppBar(title: const Text('Voids')),
        body: const EmptyState(
          icon: Icons.remove_shopping_cart_outlined,
          title: 'The till is not switched on',
          message: 'Voids are a till control, and this company has no till.',
        ),
      );
    }

    final summary = ref.watch(posVoidSummaryProvider(_range));
    final bills = ref.watch(posVoidedBillsProvider(_range));

    return Scaffold(
      appBar: AppBar(title: const Text('Voids')),
      body: Column(
        children: [
          FilterBar(
            child: SegmentedButton<int>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: 1, label: Text('Today')),
                ButtonSegment(value: 7, label: Text('7 days')),
                ButtonSegment(value: 30, label: Text('30 days')),
              ],
              selected: {_range.to.difference(_range.from).inDays + 1},
              onSelectionChanged: (s) =>
                  setState(() => _range = _lastDays(s.first)),
            ),
          ),
          Expanded(
            child: AsyncView<List<Map<String, dynamic>>>(
              value: summary,
              onRetry: () => ref.invalidate(posVoidSummaryProvider(_range)),
              builder: (rows) {
                final written = bills.valueOrNull ?? const [];
                if (rows.isEmpty && written.isEmpty) {
                  return const EmptyState(
                    icon: Icons.remove_shopping_cart_outlined,
                    title: 'Nothing came off a bill',
                    message:
                        'Lines taken off after the kitchen was told show up '
                        'here, grouped by the reason given — and whole bills '
                        'written off are listed one by one underneath.',
                  );
                }
                final total = rows.fold<double>(
                  0,
                  (n, r) => n + Fmt.toDouble(r['value']),
                );
                return ListView(
                  padding: const EdgeInsets.only(bottom: Space.xxl),
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(
                        Space.lg,
                        Space.md,
                        Space.lg,
                        0,
                      ),
                      child: StatTile(
                        label: 'Off the bills',
                        value: Fmt.money(total),
                        // The count of reasons, not of voids: the point
                        // of the grouping is how many kinds of thing are
                        // happening, and the per-reason counts are on
                        // the rows below.
                        caption:
                            '${rows.length} reason${rows.length == 1 ? '' : 's'} '
                            'over ${_range.to.difference(_range.from).inDays + 1} '
                            'day${_range.to.difference(_range.from).inDays == 0 ? '' : 's'}',
                      ),
                    ),
                    for (final r in rows)
                      ListTile(
                        title: Text(Fmt.label('${r['reason']}')),
                        subtitle: Text(
                          '${r['lines']} line${r['lines'] == 1 ? '' : 's'} · '
                          '${Fmt.qty(Fmt.toDouble(r['quantity']))} items',
                        ),
                        trailing: Money(Fmt.toDouble(r['value']), bold: true),
                      ),
                    // Whole bills, listed rather than grouped. There are
                    // far fewer of them, each is an entire order, and
                    // the question is which one and whose — grouping
                    // would hide the only fact that matters.
                    //
                    // They must be here even when the summary above is
                    // empty: a bill written off before the kitchen
                    // cooked anything leaves no line voids, which is the
                    // exact case the grant exists to control.
                    if (written.isNotEmpty) ...[
                      Padding(
                        padding: const EdgeInsets.fromLTRB(
                          Space.lg,
                          Space.xl,
                          Space.lg,
                          Space.sm,
                        ),
                        child: Text(
                          'Bills written off',
                          style: Theme.of(context).textTheme.titleSmall,
                        ),
                      ),
                      for (final b in written)
                        ListTile(
                          title: Text(
                            [
                              '${b['sale_no']}',
                              if ('${b['table_code'] ?? ''}'.isNotEmpty)
                                '${b['table_code']}',
                            ].join('  ·  '),
                          ),
                          subtitle: Text(
                            [
                              [
                                Fmt.label('${b['reason'] ?? ''}'),
                                // The difference between food lost and
                                // an order that never existed, which a
                                // manager reads differently.
                                '${b['cooked_count']} of '
                                    '${b['line_count']} cooked',
                                if ('${b['voided_name'] ?? ''}'.isNotEmpty)
                                  '${b['voided_name']}',
                              ].where((v) => v.isNotEmpty).join('  ·  '),
                              // Shown, not just stored. "Something else"
                              // is made to explain itself, and hiding
                              // the explanation would waste the one
                              // rule that makes the catch-all worth
                              // having.
                              if ('${b['note'] ?? ''}'.isNotEmpty)
                                '${b['note']}',
                            ].join('\n'),
                          ),
                          trailing: Money(
                            Fmt.toDouble(b['total_amount']),
                            bold: true,
                          ),
                          isThreeLine: '${b['note'] ?? ''}'.isNotEmpty,
                        ),
                    ],
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
