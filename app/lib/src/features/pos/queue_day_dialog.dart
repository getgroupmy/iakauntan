import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/skeletons.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';

/// What the line did on a day.
///
/// `0257` is explicit about why the paper by the door was worth
/// replacing: it "does not exist at all by Monday, so nobody ever
/// learns whether Saturday's wait is twenty minutes or fifty", and "a
/// shop that cannot say how long Saturday's wait was cannot decide
/// whether to open another section". `pos_queue_day` computes exactly
/// that and nothing watched `posQueueDayProvider` — the screen showed
/// the line standing there now and forgot it by Monday, which is the
/// paper's failing with a spinner on it.

/// How a day reads for one outlet.
///
/// Joined first, because everything else is a share of it. A zero is
/// left out: a shop reading "0 gave up" every day stops reading the
/// line, and the day it says 6 it looks the same.
String queueDayLine(Map<String, dynamic> row) {
  final joined = Fmt.toInt(row['joined']);
  if (joined == 0) return 'Nobody queued';
  final seated = Fmt.toInt(row['seated']);
  final waiting = Fmt.toInt(row['still_waiting']);
  return [
    '$joined joined',
    if (seated > 0) '$seated seated',
    if (waiting > 0) '$waiting still in the line',
  ].join(' · ');
}

/// The two ways a party leaves without eating, kept apart.
///
/// `0257` insists on the distinction and the function returns them as
/// separate columns: "one is the wait being too long and the other is
/// somebody standing outside on the phone, and a shop reading 'twelve
/// gave up' cannot tell which it had". Only one of them is a reason to
/// open another section. Null when neither happened.
String? walkedAwayLine(Map<String, dynamic> row) {
  final gaveUp = Fmt.toInt(row['gave_up']);
  final noShows = Fmt.toInt(row['no_shows']);
  if (gaveUp == 0 && noShows == 0) return null;
  return [
    if (gaveUp > 0) '$gaveUp gave up waiting',
    if (noShows > 0) '$noShows did not come when called',
  ].join(', ');
}

/// How long the wait was, in the middle of it.
///
/// The median rather than the mean, for the reason `0257` gives about
/// the quoted wait: one party that waited two hours because they went
/// to the car park should not move the figure everybody else is judged
/// by. It is null until somebody has been seated, and that is said as
/// itself rather than as nought minutes — nought minutes reads as a
/// shop with no wait, which is the opposite of what it means.
String waitLabel(Map<String, dynamic> row) {
  final median = row['median_wait'] == null
      ? null
      : Fmt.toInt(row['median_wait']);
  if (median == null) return 'nobody was seated';
  final longest = row['longest_wait'] == null
      ? null
      : Fmt.toInt(row['longest_wait']);
  if (longest == null || longest <= median) return 'about $median min';
  return 'about $median min, longest $longest';
}

/// Of the parties that joined, the share that gave up on the wait.
///
/// The one figure that answers "another section?". Null where nobody
/// joined, because none out of none is not nought per cent.
double? gaveUpShare(Map<String, dynamic> row) {
  final joined = Fmt.toInt(row['joined']);
  if (joined <= 0) return null;
  return Fmt.toInt(row['gave_up']) / joined;
}

/// The whole day, across every outlet.
///
/// The longest wait of any of them, rather than a median of medians:
/// there is no honest way to average one shop's middle against
/// another's without the party counts, and the worst queue anybody
/// stood in is the number that decides anything.
({int joined, int seated, int gaveUp, int noShows, int stillWaiting,
  int? longestWait}) queueDayTotals(Iterable<Map<String, dynamic>> rows) {
  var joined = 0, seated = 0, gaveUp = 0, noShows = 0, waiting = 0;
  int? longest;
  for (final r in rows) {
    joined += Fmt.toInt(r['joined']);
    seated += Fmt.toInt(r['seated']);
    gaveUp += Fmt.toInt(r['gave_up']);
    noShows += Fmt.toInt(r['no_shows']);
    waiting += Fmt.toInt(r['still_waiting']);
    final l = r['longest_wait'] == null ? null : Fmt.toInt(r['longest_wait']);
    if (l != null && (longest == null || l > longest)) longest = l;
  }
  return (
    joined: joined,
    seated: seated,
    gaveUp: gaveUp,
    noShows: noShows,
    stillWaiting: waiting,
    longestWait: longest,
  );
}

/// What the line did on a day.
Future<void> showQueueDay(BuildContext context) => showDialog<void>(
      context: context,
      builder: (_) => const _QueueDayDialog(),
    );

class _QueueDayDialog extends ConsumerStatefulWidget {
  const _QueueDayDialog();

  @override
  ConsumerState<_QueueDayDialog> createState() => _QueueDayDialogState();
}

class _QueueDayDialogState extends ConsumerState<_QueueDayDialog> {
  DateTime _day = DateTime.now();

  DateTime get _date => DateTime(_day.year, _day.month, _day.day);

  @override
  Widget build(BuildContext context) {
    final day = ref.watch(posQueueDayProvider(_date));
    final small = Theme.of(context).textTheme.bodySmall;

    return AlertDialog(
      title: const Text('What the line did'),
      content: SizedBox(
        width: 560,
        height: 440,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(child: Text(Fmt.date(_date))),
                TextButton.icon(
                  key: const ValueKey('queue-day-date'),
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
                value: day,
                onRetry: () => ref.invalidate(posQueueDayProvider(_date)),
                skeleton: const ListSkeleton(rows: 4, leading: false),
                builder: (shops) {
                  if (shops.isEmpty) {
                    return const EmptyState(
                      icon: Icons.people_outline,
                      title: 'No outlets',
                      message: 'There is nowhere to keep a line.',
                    );
                  }
                  final totals = queueDayTotals(shops);
                  return ListView(
                    children: [
                      for (final s in shops)
                        ListTile(
                          dense: true,
                          title: Text('${s['outlet_name']}'),
                          subtitle: Text(
                            [
                              queueDayLine(s),
                              waitLabel(s),
                              if (walkedAwayLine(s) != null)
                                walkedAwayLine(s)!,
                            ].join(' · '),
                            style: const TextStyle(fontSize: 12),
                          ),
                          // The one figure that answers "another
                          // section?", per shop. Only where it is not
                          // nought — a column of 0% teaches nobody
                          // anything and hides the one that is 30.
                          trailing: switch (gaveUpShare(s)) {
                            null || 0 => null,
                            final share => Text(
                                '${(share * 100).round()}% gave up',
                                style: small?.copyWith(
                                  color: context.colors.warning,
                                ),
                              ),
                          },
                        ),
                      const Divider(height: 1),
                      Padding(
                        padding: const EdgeInsets.all(Space.lg),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '${totals.joined} joined, '
                              '${totals.seated} seated'
                              '${totals.longestWait == null ? '' : ', longest wait ${totals.longestWait} min'}',
                              style: small,
                            ),
                            if (totals.gaveUp > 0)
                              Padding(
                                padding: const EdgeInsets.only(top: Space.sm),
                                child: Text(
                                  '${totals.gaveUp} gave up waiting. That is '
                                  'the number another section would be '
                                  'opened for; '
                                  '${totals.noShows} did not come when '
                                  'called, which no amount of seating fixes.',
                                  style: small?.copyWith(
                                    color: context.colors.warning,
                                  ),
                                ),
                              ),
                          ],
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
