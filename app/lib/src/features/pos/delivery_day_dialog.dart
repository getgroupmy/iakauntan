import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/skeletons.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';

/// A day of delivering, and what each driver carried.
///
/// `pos_delivery_day` and `pos_driver_runs` are both in the schema and
/// neither reached a screen: `posDeliveryDay` had no provider at all
/// and `posDriverRunsProvider` was watched by nothing. A shop running
/// deliveries recorded every driver, every run, every fee and every
/// delivery time, and could report none of it — the board shows what is
/// out right now and nothing shows what happened.

/// How a day reads for one outlet, or for one driver.
///
/// The four counts always add up to the runs, so they are said together
/// and in that order: what went out, what arrived, what did not, and
/// what is still on a bike. A zero is left out — a shop reading "0
/// failed" every day stops reading the line at all, and the day it
/// says 3 it looks the same.
String runsLine(Map<String, dynamic> row) {
  final runs = Fmt.toInt(row['runs']);
  final delivered = Fmt.toInt(row['delivered']);
  final failed = Fmt.toInt(row['failed']);
  final out = Fmt.toInt(row['still_out']);
  return [
    '$runs out',
    if (delivered > 0) '$delivered delivered',
    if (failed > 0) '$failed failed',
    if (out > 0) '$out still out',
  ].join(' · ');
}

/// How long a run took, in the middle.
///
/// The median rather than the mean, because one driver stuck behind an
/// accident should not make the whole day look slow. Null until
/// something has actually arrived, and said as that rather than as
/// zero minutes.
String medianLabel(Object? minutes) {
  final m = minutes == null ? null : Fmt.toInt(minutes);
  if (m == null || m <= 0) return 'nothing has arrived yet';
  return 'about $m minutes, typically';
}

/// What the free-delivery promise cost, in rides given away.
///
/// Only said when it cost something: the promise is usually the point,
/// and a line saying it cost nothing is a line about nothing.
String? freeRidesLine(Map<String, dynamic> row) {
  final free = Fmt.toInt(row['free_rides']);
  if (free <= 0) return null;
  return '$free ride${free == 1 ? '' : 's'} given away';
}

/// The whole day, across every outlet.
({int runs, int delivered, int failed, int stillOut, double fees})
    deliveryDayTotals(Iterable<Map<String, dynamic>> rows) {
  var runs = 0, delivered = 0, failed = 0, out = 0;
  var fees = 0.0;
  for (final r in rows) {
    runs += Fmt.toInt(r['runs']);
    delivered += Fmt.toInt(r['delivered']);
    failed += Fmt.toInt(r['failed']);
    out += Fmt.toInt(r['still_out']);
    fees += double.tryParse('${r['fees'] ?? 0}') ?? 0;
  }
  return (
    runs: runs,
    delivered: delivered,
    failed: failed,
    stillOut: out,
    fees: double.parse(fees.toStringAsFixed(2)),
  );
}

/// What a day of delivering came to.
Future<void> showDeliveryDay(BuildContext context) => showDialog<void>(
      context: context,
      builder: (_) => const _DayDialog(),
    );

class _DayDialog extends ConsumerStatefulWidget {
  const _DayDialog();

  @override
  ConsumerState<_DayDialog> createState() => _DayDialogState();
}

class _DayDialogState extends ConsumerState<_DayDialog> {
  DateTime _day = DateTime.now();

  DateTime get _date => DateTime(_day.year, _day.month, _day.day);

  @override
  Widget build(BuildContext context) {
    final outlets = ref.watch(posDeliveryDayProvider(_date));
    final drivers = ref.watch(posDriverRunsProvider(_date));

    return AlertDialog(
      title: const Text('The day’s deliveries'),
      content: SizedBox(
        width: 560,
        height: 480,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(child: Text(Fmt.date(_date))),
                TextButton.icon(
                  key: const ValueKey('delivery-day-date'),
                  onPressed: () async {
                    final picked = await showDatePicker(
                      context: context,
                      initialDate: _date,
                      firstDate: DateTime(_date.year - 2),
                      lastDate: DateTime.now(),
                    );
                    if (picked != null) setState(() => _day = picked);
                  },
                  icon: const Icon(Icons.event_outlined, size: 18),
                  label: const Text('Another day'),
                ),
              ],
            ),
            const Divider(height: 1),
            Expanded(
              child: AsyncView<List<Map<String, dynamic>>>(
                value: outlets,
                onRetry: () => ref.invalidate(posDeliveryDayProvider(_date)),
                skeleton: const ListSkeleton(rows: 4, leading: false),
                builder: (shops) {
                  if (shops.isEmpty) {
                    return const EmptyState(
                      icon: Icons.moped_outlined,
                      title: 'Nothing went out',
                      message: 'No bill had an address on it that day.',
                    );
                  }
                  final totals = deliveryDayTotals(shops);
                  return ListView(
                    children: [
                      for (final s in shops)
                        ListTile(
                          dense: true,
                          title: Text('${s['outlet_name']}'),
                          subtitle: Text(
                            [
                              runsLine(s),
                              medianLabel(s['median_minutes']),
                              if (freeRidesLine(s) != null) freeRidesLine(s)!,
                            ].join(' · '),
                            style: const TextStyle(fontSize: 12),
                          ),
                          trailing: Money(
                            num.tryParse('${s['fees'] ?? 0}'),
                          ),
                        ),
                      const Divider(height: 1),
                      Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: Space.lg,
                          vertical: Space.sm,
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                '${totals.runs} out, '
                                '${totals.delivered} delivered'
                                '${totals.failed > 0 ? ', ${totals.failed} failed' : ''}',
                                style:
                                    Theme.of(context).textTheme.bodySmall,
                              ),
                            ),
                            Money(totals.fees, bold: true),
                          ],
                        ),
                      ),
                      const SectionHeader(
                        'Who carried it',
                        subtitle: 'What each driver did that day',
                      ),
                      drivers.maybeWhen(
                        data: (rows) => rows.isEmpty
                            ? Padding(
                                padding: const EdgeInsets.all(Space.lg),
                                child: Text(
                                  'Nothing was assigned to a driver.',
                                  style:
                                      Theme.of(context).textTheme.bodySmall,
                                ),
                              )
                            : Column(
                                children: [
                                  for (final d in rows)
                                    ListTile(
                                      dense: true,
                                      title: Text('${d['driver_name']}'),
                                      subtitle: Text(
                                        [
                                          '${d['outlet_name']}',
                                          runsLine(d),
                                          medianLabel(d['median_minutes']),
                                        ].join(' · '),
                                        style: const TextStyle(fontSize: 12),
                                      ),
                                      trailing: Money(
                                        num.tryParse('${d['fees'] ?? 0}'),
                                      ),
                                    ),
                                ],
                              ),
                        orElse: () => const Padding(
                          padding: EdgeInsets.all(Space.lg),
                          child: LinearProgressIndicator(),
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }
}
