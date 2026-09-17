import 'package:flutter_test/flutter_test.dart';
import 'package:iakauntan/src/features/pos/queue_day_dialog.dart';

Map<String, dynamic> outlet({
  int joined = 0,
  int seated = 0,
  int gaveUp = 0,
  int noShows = 0,
  int stillWaiting = 0,
  int? median,
  int? longest,
}) => {
  'outlet_name': 'Jalan Ampang',
  'joined': joined,
  'seated': seated,
  'gave_up': gaveUp,
  'no_shows': noShows,
  'still_waiting': stillWaiting,
  'median_wait': median,
  'longest_wait': longest,
};

void main() {
  group('how a day reads', () {
    test('joined first, because the rest is a share of it', () {
      expect(
        queueDayLine(outlet(joined: 31, seated: 24)),
        '31 joined · 24 seated',
      );
    });

    test('and what is still standing there is said', () {
      expect(
        queueDayLine(outlet(joined: 31, seated: 24, stillWaiting: 3)),
        '31 joined · 24 seated · 3 still in the line',
      );
    });

    test('a shop that ran no queue says so', () {
      // The function left-joins so a quiet shop is a row of noughts
      // rather than missing: its absence would read as no problem.
      expect(queueDayLine(outlet()), 'Nobody queued');
    });

    test('a nought is left out rather than printed', () {
      expect(queueDayLine(outlet(joined: 4)), '4 joined');
    });
  });

  group('the two ways a party leaves without eating', () {
    test('are never added together', () {
      expect(
        walkedAwayLine(outlet(gaveUp: 12, noShows: 3)),
        '12 gave up waiting, 3 did not come when called',
      );
    });

    test('and either stands alone', () {
      expect(walkedAwayLine(outlet(gaveUp: 12)), '12 gave up waiting');
      expect(
        walkedAwayLine(outlet(noShows: 3)),
        '3 did not come when called',
      );
    });

    test('a day nobody walked off says nothing at all', () {
      expect(walkedAwayLine(outlet(joined: 20, seated: 20)), isNull);
    });
  });

  group('how long the wait was', () {
    test('the middle of it, and the worst of it', () {
      expect(
        waitLabel(outlet(median: 18, longest: 47)),
        'about 18 min, longest 47',
      );
    });

    test('the worst is left out when it is the middle', () {
      // One party seated: the median and the maximum are the same
      // minute, and saying it twice reads as two facts.
      expect(waitLabel(outlet(median: 18, longest: 18)), 'about 18 min');
    });

    test('nobody seated is said as itself, not as nought minutes', () {
      // Nought minutes reads as a shop with no wait, which is the
      // opposite of a shop where nobody ever got a table.
      expect(waitLabel(outlet(joined: 9)), 'nobody was seated');
    });

    test('a wait of under a minute is still a wait', () {
      expect(waitLabel(outlet(median: 0, longest: 0)), 'about 0 min');
    });
  });

  group('the share that gave up', () {
    test('is out of everybody who joined', () {
      expect(gaveUpShare(outlet(joined: 40, gaveUp: 10)), 0.25);
    });

    test('and is nothing where nobody joined', () {
      // None out of none is not nought per cent.
      expect(gaveUpShare(outlet()), isNull);
    });

    test('a day nobody gave up on is nought', () {
      expect(gaveUpShare(outlet(joined: 40, seated: 40)), 0);
    });
  });

  group('the day across every outlet', () {
    final shops = [
      outlet(joined: 31, seated: 24, gaveUp: 5, noShows: 2, stillWaiting: 3,
          median: 18, longest: 47),
      outlet(joined: 12, seated: 12, median: 9, longest: 61),
      outlet(),
    ];

    test('adds every count up', () {
      final t = queueDayTotals(shops);
      expect(t.joined, 43);
      expect(t.seated, 36);
      expect(t.gaveUp, 5);
      expect(t.noShows, 2);
      expect(t.stillWaiting, 3);
    });

    test('and takes the worst wait anybody stood in', () {
      // Not a median of medians: there is no honest way to average one
      // shop's middle against another's without the party counts, and
      // the quiet shop's one long wait is still a customer who waited.
      expect(queueDayTotals(shops).longestWait, 61);
    });

    test('a day where nobody was seated anywhere has no longest', () {
      expect(queueDayTotals([outlet(joined: 4), outlet()]).longestWait, isNull);
    });

    test('nothing at all totals to noughts', () {
      final t = queueDayTotals(const []);
      expect(t.joined, 0);
      expect(t.stillWaiting, 0);
      expect(t.longestWait, isNull);
    });
  });
}
