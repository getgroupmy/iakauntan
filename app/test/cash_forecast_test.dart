import 'package:flutter_test/flutter_test.dart';
import 'package:iakauntan/src/features/reports/cash_forecast_screen.dart';

void main() {
  final today = DateTime(2026, 8, 22);

  group('runsOutLabel', () {
    test('says nothing alarming when the bank stays in credit', () {
      expect(
        runsOutLabel(null, today),
        'The bank stays in credit the whole way',
      );
    });

    test('counts the weeks, because that is what somebody acts on', () {
      // A date on its own is a fact. "In six weeks" is a decision.
      expect(
        runsOutLabel(DateTime(2026, 10, 3), today),
        'The bank runs short in 6 weeks — 03/10/2026',
      );
      expect(
        runsOutLabel(DateTime(2026, 8, 29), today),
        'The bank runs short in 1 week — 29/08/2026',
      );
    });

    test('and falls back to days inside the first week', () {
      expect(
        runsOutLabel(DateTime(2026, 8, 25), today),
        'The bank runs short in 3 days',
      );
    });

    test('says it plainly when the money has already gone', () {
      expect(runsOutLabel(today, today), 'The bank is short now');
      expect(
        runsOutLabel(DateTime(2026, 8, 20), today),
        'The bank is short now',
      );
    });
  });

  group('movementSource', () {
    test('names every source in words a reader recognises', () {
      expect(movementSource('invoice'), 'A customer invoice');
      expect(movementSource('bill'), 'A supplier bill');
      expect(movementSource('cheque'), 'A post-dated cheque');
      expect(movementSource('recurring'), 'A recurring document');
      expect(movementSource('payroll'), 'Wages');
      expect(movementSource('manual'), 'Entered by hand');
    });
  });

  group('weekLabel', () {
    test('numbers the week and dates it', () {
      expect(
        weekLabel({'week_no': 3, 'week_start': '2026-09-05'}),
        'Week 3 · 05/09/2026',
      );
    });
  });

  group('lagLabel', () {
    test('says what a customer actually does, either way', () {
      expect(lagLabel({'lag_days': 45}), 'Takes 45 days longer than the terms');
      expect(lagLabel({'lag_days': 1}), 'Takes 1 day longer than the terms');
      expect(lagLabel({'lag_days': 0}), 'Pays on the day');
      expect(lagLabel({'lag_days': -3}), 'Pays 3 days early');
      expect(lagLabel({'lag_days': -1}), 'Pays 1 day early');
    });
  });

  group('whose habit moves the forecast', () {
    Map<String, dynamic> lag(String party, {int days = 30, num owed = 1000}) =>
        <String, dynamic>{
          'party': party,
          'lag_days': days,
          'outstanding': owed,
        };

    test('only a customer with something outstanding', () {
      // A customer who owes nothing has no invoice for the lag to
      // shift, so listing them buries the names somebody came to argue
      // about.
      final rows = lagsWorthArguingAbout([
        lag('Sinar Teknologi', owed: 12000),
        lag('Paid Up Sdn Bhd', owed: 0),
        lag('Amanah', owed: 500),
      ]);
      expect(rows.map((r) => r['party']), ['Sinar Teknologi', 'Amanah']);
    });

    test('the order the function returned is kept — latest first', () {
      // customer_payment_lags orders by lag descending, which is the
      // order the argument goes in.
      final rows = lagsWorthArguingAbout([
        lag('Worst', days: 90),
        lag('Middling', days: 20),
        lag('Prompt', days: 0),
      ]);
      expect(rows.map((r) => r['party']), ['Worst', 'Middling', 'Prompt']);
    });

    test('a customer who pays early is still listed', () {
      // It is the customer nobody chases, and the forecast pulls their
      // receipt forward.
      final rows = lagsWorthArguingAbout([lag('Early', days: -5)]);
      expect(rows, hasLength(1));
    });

    test('nothing owed anywhere is an empty list', () {
      expect(lagsWorthArguingAbout([lag('A', owed: 0)]), isEmpty);
    });

    test('what the lags are holding up', () {
      expect(
        lagsOutstanding([lag('A', owed: 1200), lag('B', owed: 340.50)]),
        1540.50,
      );
      expect(lagsOutstanding(const []), 0);
    });

    test('and it is rounded to the sen', () {
      // 0.1 + 0.2 is 0.30000000000000004 in a double, and a total
      // shown beside individual figures has to agree with their sum.
      expect(
        lagsOutstanding([lag('A', owed: 0.1), lag('B', owed: 0.2)]),
        0.30,
      );
    });

    test('amounts that arrive as strings still add up', () {
      expect(
        lagsOutstanding([
          <String, dynamic>{'outstanding': '1200.00'},
          <String, dynamic>{'outstanding': '340.50'},
        ]),
        1540.50,
      );
    });

    test('the provenance says how far back the number looks', () {
      // app.contact_payment_lag averages the last twelve settled
      // invoices and clamps each at 180 days.
      expect(lagsProvenance, contains('twelve'));
      expect(lagsProvenance, contains('180'));
    });
  });
}
