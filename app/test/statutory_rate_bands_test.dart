import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/features/admin/statutory_rates_admin.dart';

/// The wage bands a statutory schedule is made of.
///
/// `rateTableProblem` is what stands between a published EPF, SOCSO or
/// EIS schedule and a contribution table with a hole in it, and it had
/// no test. CLAUDE.md is explicit that anything touching those needs an
/// assertion that would fail if the number moved.
///
/// The function's own words are the stakes: the database refuses an
/// empty schedule and an unknown rounding mode, and these are the
/// mistakes it would ACCEPT — a band that ends before it starts, and a
/// gap or overlap between consecutive bands, "both of which produce a
/// wage that lands in no band and a deduction of zero on somebody's
/// payslip".
///
/// A deduction of zero is not a visible failure. It is a payslip that
/// looks ordinary and an employee who is not contributing, found at the
/// next audit or not at all.
void main() {
  RateDraft band({
    String category = 'default',
    double from = 0,
    double? to,
    double employee = 0.11,
    double employer = 0.13,
  }) => RateDraft(
    category: category,
    wageFrom: from,
    wageTo: to,
    employeeRate: employee,
    employerRate: employer,
  );

  /// A schedule shaped the way a real one is: contiguous from zero, and
  /// open-ended at the top so no wage falls off the end of it.
  List<RateDraft> wholeSchedule() => [
    band(from: 0, to: 5000),
    band(from: 5000, to: 20000),
    band(from: 20000),
  ];

  group('a schedule that is sound', () {
    test('has nothing wrong with it', () {
      expect(rateTableProblem(wholeSchedule()), isNull);
    });

    test('and is sound whatever order the bands were entered in', () {
      // The function sorts before it checks, which is what lets an
      // administrator add a band in the middle without reordering the
      // whole table by hand. Asserted because the sort is the only
      // reason the loop below it means anything.
      final shuffled = [
        band(from: 20000),
        band(from: 0, to: 5000),
        band(from: 5000, to: 20000),
      ];

      expect(rateTableProblem(shuffled), isNull);
    });

    test('and each category is judged on its own', () {
      // SOCSO has separate tables for the two categories of employment.
      // One complete schedule per category is correct; reading them as
      // one list would see gaps and overlaps that are not there.
      final both = [
        band(category: 'first', from: 0, to: 5000),
        band(category: 'first', from: 5000),
        band(category: 'second', from: 0, to: 5000),
        band(category: 'second', from: 5000),
      ];

      expect(rateTableProblem(both), isNull);
    });
  });

  group('a wage that would fall outside every band', () {
    test('a gap between two bands is refused, and named', () {
      // 5,000 to 5,100 belongs to nobody. A wage in that range deducts
      // nothing at all.
      final gapped = [
        band(from: 0, to: 5000),
        band(from: 5100),
      ];

      final said = rateTableProblem(gapped)!;
      expect(said, contains('gap or overlap'));
      // The money is named, so the administrator knows where to look
      // rather than being told the table is wrong.
      expect(said, contains('5,000.00'));
    });

    test('and an overlap is refused by the same rule', () {
      // 4,000 to 5,000 belongs to both. Which one a wage lands in is
      // then an accident of the query plan.
      final overlapping = [
        band(from: 0, to: 5000),
        band(from: 4000),
      ];

      expect(rateTableProblem(overlapping), contains('gap or overlap'));
    });

    test('a schedule that does not start at zero is refused', () {
      // The lowest wages are the ones a statutory floor exists for.
      final floating = [
        band(from: 100, to: 5000),
        band(from: 5000),
      ];

      expect(
        rateTableProblem(floating),
        contains('start above zero'),
      );
    });

    test('and one that is closed at the top is refused', () {
      // A wage above the last band deducts nothing. The top band has no
      // upper limit precisely so that cannot happen.
      final capped = [
        band(from: 0, to: 5000),
        band(from: 5000, to: 20000),
      ];

      expect(
        rateTableProblem(capped),
        contains('needs no upper limit'),
      );
    });

    test('and an open-ended band in the MIDDLE is refused', () {
      // Only the top one may be open. An open band with another above
      // it swallows every wage from its floor upwards, and the bands
      // above it are never reached.
      final openInTheMiddle = [
        band(from: 0),
        band(from: 5000),
      ];

      expect(
        rateTableProblem(openInTheMiddle),
        contains('is not the last one'),
      );
    });
  });

  group('a band that is not a band', () {
    test('one that ends below where it starts is refused', () {
      expect(
        rateTableProblem([band(from: 5000, to: 1000)]),
        contains('ends below where it starts'),
      );
    });

    test('and one that starts below zero is refused', () {
      // There is no negative wage, and a band starting below zero is
      // how a table comes to overlap the one under it.
      expect(
        rateTableProblem([band(from: -1)]),
        contains('cannot start below zero'),
      );
    });

    test('and an empty schedule is refused', () {
      // The database refuses this too. Saying so here is what stops
      // somebody pressing publish and reading a constraint violation.
      expect(
        rateTableProblem(const []),
        contains('at least one band'),
      );
    });
  });

  group('the tolerance on a boundary', () {
    test('a sen of rounding between two bands is allowed', () {
      // The comparison is `> 0.011`, so a band ending at 4,999.99 and
      // the next starting at 5,000.00 is contiguous. Published tables
      // are written both ways and neither is a hole.
      final rounded = [
        band(from: 0, to: 4999.99),
        band(from: 5000),
      ];

      expect(rateTableProblem(rounded), isNull);
    });

    test('and a ringgit is not', () {
      // The control for the line above. Without it, "a sen is allowed"
      // passes against a function that allows anything.
      final gapped = [
        band(from: 0, to: 4999),
        band(from: 5000),
      ];

      expect(rateTableProblem(gapped), contains('gap or overlap'));
    });
  });
}
