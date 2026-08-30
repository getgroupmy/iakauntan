import 'package:flutter_test/flutter_test.dart';
import 'package:iakauntan/src/data/models.dart';
import 'package:iakauntan/src/features/legal/matter_billing.dart';
import 'package:iakauntan/src/features/timesheets/billing_rate_sheet.dart';

TimeEntry _entry({
  required String id,
  required DateTime on,
  int minutes = 60,
  double amount = 500,
  bool billable = true,
  bool billed = false,
}) =>
    TimeEntry(
      id: id,
      entryDate: on,
      description: 'Attendance',
      minutes: minutes,
      hourlyRate: 500,
      amount: amount,
      isBillable: billable,
      isBilled: billed,
    );

/// Turning recorded time into money.
///
/// `bill_matter_time` and `app.bill_time_internal` have been in `0164`
/// since the timesheets module went in, and nothing called the matter
/// one: the project side was wired from the timesheet screen and the
/// legal side was not, so a firm could record every hour of a matter
/// and never invoice one of them. The empty state even said so --
/// "record time as you work so it can be billed later" -- with nothing
/// anywhere that could bill it.
///
/// What is pressed here is which hours the RPC would take, because it
/// raises when that set is empty and a button that throws is worse than
/// a button that explains.
void main() {
  final march = DateTime(2026, 3, 1);
  final endMarch = DateTime(2026, 3, 31);

  group('which hours would be billed', () {
    test('billable, unbilled, inside the period', () {
      final e = _entry(id: 'a', on: DateTime(2026, 3, 15));
      expect(billableInPeriod([e], march, endMarch), [e]);
    });

    test('an hour already billed is left where it is', () {
      // An hour cannot be billed twice, and the SQL will not do it.
      // Counting it here would show a total the invoice never reaches.
      final e = _entry(id: 'a', on: DateTime(2026, 3, 15), billed: true);
      expect(billableInPeriod([e], march, endMarch), isEmpty);
    });

    test('non-billable time is not billed', () {
      // Written off, or pro bono. It is still recorded; it is not money.
      final e = _entry(id: 'a', on: DateTime(2026, 3, 15), billable: false);
      expect(billableInPeriod([e], march, endMarch), isEmpty);
    });

    test('an entry worth nothing is not an invoice line', () {
      final e = _entry(id: 'a', on: DateTime(2026, 3, 15), amount: 0);
      expect(billableInPeriod([e], march, endMarch), isEmpty);
    });

    test('both ends of the period are inside it', () {
      // The SQL uses `between`, so the first and last day count. A
      // fortnight that silently dropped its last day would leave hours
      // behind for somebody to find months later.
      final first = _entry(id: 'a', on: DateTime(2026, 3, 1));
      final last = _entry(id: 'b', on: DateTime(2026, 3, 31));
      expect(billableInPeriod([first, last], march, endMarch).length, 2);
    });

    test('and the days either side are not', () {
      final before = _entry(id: 'a', on: DateTime(2026, 2, 28));
      final after = _entry(id: 'b', on: DateTime(2026, 4, 1));
      expect(billableInPeriod([before, after], march, endMarch), isEmpty);
    });

    test('the time of day does not move an entry out of the period', () {
      // An entry stamped late on the last day is still on the last day.
      final e = _entry(id: 'a', on: DateTime(2026, 3, 31, 23, 45));
      expect(billableInPeriod([e], march, endMarch), [e]);
    });
  });

  group('what the invoice would come to', () {
    test('the sum of what would be billed', () {
      final entries = [
        _entry(id: 'a', on: DateTime(2026, 3, 2), amount: 500),
        _entry(id: 'b', on: DateTime(2026, 3, 9), amount: 250.50),
      ];
      expect(billableTotal(entries), 750.50);
    });

    test('rounded to the sen', () {
      final entries = [
        _entry(id: 'a', on: march, amount: 0.1),
        _entry(id: 'b', on: march, amount: 0.2),
      ];
      expect(billableTotal(entries), 0.30);
    });

    test('nothing to bill is nothing, not a null', () {
      expect(billableTotal(const []), 0);
    });
  });

  group('the hours behind it', () {
    test('come from the minutes recorded', () {
      final entries = [
        _entry(id: 'a', on: march, minutes: 90),
        _entry(id: 'b', on: march, minutes: 30),
      ];
      expect(billableHours(entries), 2);
    });

    test('and a six minute unit is a tenth of an hour', () {
      // Firms record in six-minute units, so this is the ordinary case
      // rather than an edge.
      expect(billableHours([_entry(id: 'a', on: march, minutes: 6)]), 0.10);
    });
  });

  group('the period', () {
    test('has to run forwards', () {
      // `bill_time_internal` raises 'The period ends before it starts',
      // and a date picker set by hand is how that happens.
      expect(periodRunsForward(endMarch, march), isFalse);
    });

    test('a single day is a period', () {
      expect(periodRunsForward(march, march), isTrue);
    });
  });

  group('what a rate row applies to', () {
    test('no project means the person default', () {
      expect(rateScope(null), 'Default rate');
      expect(rateScope('p1'), 'On one project');
    });

    test('null is written, not left out', () {
      // It is what makes the row a default rather than a project rate,
      // and `billing_rates_default_idx` is partial on exactly that.
      final v = billingRateValues(
        userId: 'u1', effectiveFrom: DateTime(2026, 1, 1), hourlyRate: 450,
      );
      expect(v.containsKey('project_id'), isTrue);
      expect(v['project_id'], isNull);
      expect(v['effective_from'], '2026-01-01');
      expect(v['hourly_rate'], 450);
    });

    test('blank notes are null rather than an empty string', () {
      final v = billingRateValues(
        userId: 'u1', effectiveFrom: DateTime(2026, 1, 1),
        hourlyRate: 450, notes: '   ',
      );
      expect(v['notes'], isNull);
    });

    test('a rate of nothing is a rate somebody resolved', () {
      expect(hourlyRateOf('0'), 0);
      expect(hourlyRateOf('1,250.50'), 1250.50);
      expect(hourlyRateOf('-1'), isNull);
    });
  });

  group('which rate is in force', () {
    final rates = [
      {
        'user_id': 'u1',
        'project_id': null,
        'effective_from': '2025-01-01',
        'hourly_rate': 400,
      },
      {
        'user_id': 'u1',
        'project_id': null,
        'effective_from': '2026-01-01',
        'hourly_rate': 450,
      },
      {
        'user_id': 'u1',
        'project_id': 'p1',
        'effective_from': '2025-06-01',
        'hourly_rate': 380,
      },
      {
        'user_id': 'u2',
        'project_id': null,
        'effective_from': '2026-01-01',
        'hourly_rate': 900,
      },
    ];

    test('the latest that has taken effect', () {
      final r = rateInForce(rates, 'u1', DateTime(2026, 3, 1));
      expect(r?['hourly_rate'], 450);
    });

    test('and not one that starts next year', () {
      // A rate resolved in advance is not the rate today.
      final r = rateInForce(rates, 'u1', DateTime(2025, 6, 1));
      expect(r?['hourly_rate'], 400);
    });

    test('a rate effective today is in force today', () {
      final r = rateInForce(rates, 'u1', DateTime(2026, 1, 1));
      expect(r?['hourly_rate'], 450);
    });

    test('a project rate beats the default', () {
      final r = rateInForce(rates, 'u1', DateTime(2026, 3, 1), projectId: 'p1');
      expect(r?['hourly_rate'], 380);
    });

    test('even when the default is more recent', () {
      // The project rate was agreed for that project. A later general
      // rise does not silently override what the client was quoted.
      final r = rateInForce(rates, 'u1', DateTime(2026, 3, 1), projectId: 'p1');
      expect(r?['project_id'], 'p1');
    });

    test('and whichever order the rows arrive in', () {
      // The precedence is a rule about the rows, not about the order a
      // query happened to return them in. With the project rate found
      // first, a later default must not quietly replace it -- which is
      // the same client being billed at a rate nobody quoted them.
      final reversed = [
        {
          'user_id': 'u1',
          'project_id': 'p1',
          'effective_from': '2025-06-01',
          'hourly_rate': 380,
        },
        {
          'user_id': 'u1',
          'project_id': null,
          'effective_from': '2026-01-01',
          'hourly_rate': 450,
        },
      ];
      final r =
          rateInForce(reversed, 'u1', DateTime(2026, 3, 1), projectId: 'p1');
      expect(r?['hourly_rate'], 380);
    });

    test('another project rate says nothing about this one', () {
      final r = rateInForce(rates, 'u1', DateTime(2026, 3, 1), projectId: 'p2');
      expect(r?['hourly_rate'], 450);
      expect(r?['project_id'], isNull);
    });

    test('one person rate is not another person rate', () {
      final r = rateInForce(rates, 'u2', DateTime(2026, 3, 1));
      expect(r?['hourly_rate'], 900);
    });

    test('somebody with no rate recorded has none', () {
      expect(rateInForce(rates, 'u3', DateTime(2026, 3, 1)), isNull);
      expect(rateInForce(rates, 'u1', DateTime(2024, 1, 1)), isNull);
    });
  });
}
