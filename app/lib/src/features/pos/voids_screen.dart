import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
// `RepoPosControls` is an extension, and a Dart extension is only in
// scope where its declaring library is imported.
import '../../data/repository.dart';

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
                if (rows.isEmpty) {
                  return const EmptyState(
                    icon: Icons.remove_shopping_cart_outlined,
                    title: 'Nothing came off a bill',
                    message:
                        'Lines taken off after the kitchen was told show up '
                        'here, grouped by the reason given.',
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
