import 'package:flutter_test/flutter_test.dart';
import 'package:iakauntan/src/features/admin/statutory_rates_admin.dart';

/// A statutory rate table with a gap in it does not fail. It produces a
/// deduction of zero for every wage that falls in the gap, on a payslip
/// that looks like every other payslip. The database cannot catch that
/// — a band is a valid row whatever its neighbours say — so this is the
/// one place it can be caught, and it is worth asserting.
void main() {
  RateDraft band(double from, double? to,
          {double employee = 11, String category = 'default'}) =>
      RateDraft(
        category: category,
        wageFrom: from,
        wageTo: to,
        employeeRate: employee,
      );

  group('rateTableProblem', () {
    test('accepts a contiguous table ending open', () {
      expect(
        rateTableProblem([
          band(0, 5000),
          band(5000, 20000),
          band(20000, null),
        ]),
        isNull,
      );
    });

    test('accepts a single band covering everything', () {
      expect(rateTableProblem([band(0, null)]), isNull);
    });

    test('refuses an empty table', () {
      expect(rateTableProblem([]), isNotNull);
    });

    test('refuses a band that ends below where it starts', () {
      expect(rateTableProblem([band(5000, 1000)]), contains('below'));
    });

    test('refuses a table that does not start at zero', () {
      // Everybody earning less than the first band would be deducted
      // nothing, and nothing on the payslip would say so.
      expect(
        rateTableProblem([band(100, 5000), band(5000, null)]),
        contains('above zero'),
      );
    });

    test('names the wage where a gap opens', () {
      final problem = rateTableProblem([
        band(0, 5000),
        band(6000, null),
      ]);
      expect(problem, isNotNull);
      expect(problem, contains('5,000'));
    });

    test('catches an overlap as well as a gap', () {
      expect(
        rateTableProblem([
          band(0, 5000),
          band(4000, null),
        ]),
        contains('gap or overlap'),
      );
    });

    test('refuses a table with no open top band', () {
      expect(
        rateTableProblem([band(0, 5000), band(5000, 20000)]),
        contains('no upper limit'),
      );
    });

    test('refuses an open band that is not last', () {
      expect(
        rateTableProblem([band(0, null), band(5000, null)]),
        contains('not the last one'),
      );
    });

    test('checks each category separately', () {
      // SOCSO has different tables by category; a complete set for one
      // must not excuse an incomplete set for another.
      expect(
        rateTableProblem([
          band(0, null, category: 'under60'),
          band(0, 5000, category: 'over60'),
        ]),
        contains('over60'),
      );

      expect(
        rateTableProblem([
          band(0, null, category: 'under60'),
          band(0, null, category: 'over60'),
        ]),
        isNull,
      );
    });

    test('tolerates a one-cent seam between bands', () {
      // Published tables are written as 0–4,999.99 then 5,000; treating
      // that as a gap would reject every real rate table.
      expect(
        rateTableProblem([
          band(0, 4999.99),
          band(5000, null),
        ]),
        isNull,
      );
    });
  });

  group('RateDraft.toJson', () {
    test('omits the optional columns rather than sending nulls', () {
      final json = RateDraft(wageFrom: 0, employeeRate: 11, employerRate: 13)
          .toJson();
      expect(json['wage_from'], 0);
      expect(json['employee_rate'], 11);
      expect(json.containsKey('wage_to'), isFalse);
      expect(json.containsKey('employee_amount'), isFalse);
      expect(json.containsKey('wage_ceiling'), isFalse);
    });

    test('sends a flat amount when the band is one', () {
      final json = RateDraft(employeeAmount: 4.75, employerAmount: 16.65,
              wageTo: 3000, wageCeiling: 6000)
          .toJson();
      expect(json['employee_amount'], 4.75);
      expect(json['employer_amount'], 16.65);
      expect(json['wage_to'], 3000);
      expect(json['wage_ceiling'], 6000);
    });
  });
}
