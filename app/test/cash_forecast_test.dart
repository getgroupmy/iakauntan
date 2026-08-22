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
}
