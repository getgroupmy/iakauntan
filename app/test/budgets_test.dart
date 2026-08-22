import 'package:flutter_test/flutter_test.dart';
import 'package:iakauntan/src/features/reports/budgets_screen.dart';

void main() {
  group('budgetSummary', () {
    test('says the year and how much is in it', () {
      expect(
        budgetSummary({'year_name': 'FY2026', 'lines': 48}),
        'FY2026 · 48 lines',
      );
    });

    test('names the department when there is one', () {
      expect(
        budgetSummary({
          'year_name': 'FY2026',
          'department_code': 'BAKERY',
          'lines': 12,
        }),
        'FY2026 · BAKERY · 12 lines',
      );
    });

    test('and says so plainly when there is nothing in it', () {
      // "0 lines" reads as a failure; "nothing in it yet" reads as a
      // thing that has not happened.
      expect(
        budgetSummary({'year_name': 'FY2026', 'lines': 0}),
        'FY2026 · nothing in it yet',
      );
    });
  });

  group('varianceLabel', () {
    test('says over, under, and by what percentage', () {
      expect(
        varianceLabel({'variance': 5000, 'variance_pct': 25}),
        'RM 5,000.00 over · 25.0%',
      );
      expect(
        varianceLabel({'variance': -10000, 'variance_pct': -20}),
        'RM 10,000.00 under · 20.0%',
      );
    });

    test('drops the percentage when there was no budget to compare to', () {
      // Nothing has no percentage, and "∞%" helps nobody.
      expect(varianceLabel({'variance': 900}), 'RM 900.00 over');
    });

    test('and says on plan rather than RM 0.00 over', () {
      expect(varianceLabel({'variance': 0, 'variance_pct': 0}), 'On plan');
    });
  });

  group('periodRangeLabel', () {
    test('names the ranges somebody actually asks for', () {
      expect(periodRangeLabel(1, 12), 'The whole year');
      expect(periodRangeLabel(1, 3), 'First quarter');
      expect(periodRangeLabel(4, 4), 'Period 4');
      expect(periodRangeLabel(1, 8), 'Year to period 8');
      expect(periodRangeLabel(4, 6), 'Periods 4 to 6');
    });
  });
}
