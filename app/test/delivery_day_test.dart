import 'package:flutter_test/flutter_test.dart';
import 'package:iakauntan/src/features/pos/delivery_day_dialog.dart';

Map<String, dynamic> day({
  int runs = 18,
  int delivered = 15,
  int failed = 0,
  int stillOut = 0,
  num fees = 108,
  int? median = 24,
  int free = 0,
}) => <String, dynamic>{
  'outlet_name': 'Bangsar',
  'runs': runs,
  'delivered': delivered,
  'failed': failed,
  'still_out': stillOut,
  'fees': fees,
  'free_rides': free,
  'median_minutes': median,
};

void main() {
  group('how the runs read', () {
    test('what went out, what arrived, what did not, what is still out', () {
      expect(
        runsLine(day(runs: 18, delivered: 15, failed: 2, stillOut: 1)),
        '18 out · 15 delivered · 2 failed · 1 still out',
      );
    });

    test('a zero is left out', () {
      // A shop reading "0 failed" every day stops reading the line, and
      // the day it says 3 it looks the same.
      expect(runsLine(day(runs: 18, delivered: 18)), '18 out · 18 delivered');
    });

    test('a day with nothing out still says so', () {
      expect(runsLine(day(runs: 0, delivered: 0)), '0 out');
    });

    test('the counts are read in that order', () {
      final s = runsLine(day(runs: 5, delivered: 3, failed: 1, stillOut: 1));
      expect(s.indexOf('delivered'), lessThan(s.indexOf('failed')));
      expect(s.indexOf('failed'), lessThan(s.indexOf('still out')));
    });
  });

  group('how long a run took', () {
    test('the middle of them', () {
      // The median, so one driver stuck behind an accident does not
      // make the whole day look slow.
      expect(medianLabel(24), 'about 24 minutes, typically');
    });

    test('nothing arrived yet is said as that, not as zero minutes', () {
      expect(medianLabel(null), 'nothing has arrived yet');
      expect(medianLabel(0), 'nothing has arrived yet');
    });

    test('a number that came back as a string still reads', () {
      expect(medianLabel('31'), 'about 31 minutes, typically');
    });
  });

  group('what the free-delivery promise cost', () {
    test('is said in rides given away', () {
      expect(freeRidesLine(day(free: 4)), '4 rides given away');
      expect(freeRidesLine(day(free: 1)), '1 ride given away');
    });

    test('and is not said when it cost nothing', () {
      // The promise is usually the point; a line saying it cost
      // nothing is a line about nothing.
      expect(freeRidesLine(day(free: 0)), isNull);
    });
  });

  group('the whole day across every outlet', () {
    test('adds the counts and the fees', () {
      final t = deliveryDayTotals([
        day(runs: 18, delivered: 15, failed: 2, stillOut: 1, fees: 108),
        day(runs: 7, delivered: 7, fees: 42.50),
      ]);
      expect(t.runs, 25);
      expect(t.delivered, 22);
      expect(t.failed, 2);
      expect(t.stillOut, 1);
      expect(t.fees, 150.50);
    });

    test('rounds the money to the sen', () {
      final t = deliveryDayTotals([day(fees: 0.1), day(fees: 0.2)]);
      expect(t.fees, 0.30);
    });

    test('a day with no outlets is all zeroes', () {
      final t = deliveryDayTotals(const []);
      expect(t.runs, 0);
      expect(t.fees, 0);
    });

    test('fees that arrive as strings still add up', () {
      final t = deliveryDayTotals([
        <String, dynamic>{'fees': '108.00'},
        <String, dynamic>{'fees': '42.50'},
      ]);
      expect(t.fees, 150.50);
    });
  });
}
