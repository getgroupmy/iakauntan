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

  group('a box that is not a number', () {
    // The four boxes used to read `double.tryParse(v) ?? 0`, so text
    // the parser could not read became a nought. Three of those noughts
    // are caught by the arithmetic above -- a `From` of zero on a band
    // that is not the lowest overlaps the one below it, a `To` that
    // reads as empty is an open-ended band in the middle.
    //
    // The RATE boxes have nothing behind them. Zero per cent is a real
    // band: the lowest EPF band contributes nothing, and SOCSO's second
    // category takes nothing from the employee. So no later check can
    // tell a deliberate nought from "11.5%" with the sign left on, and
    // the schedule publishes, and that wage band deducts nothing on
    // every payslip until somebody audits it.

    test('an unreadable employee rate stops the schedule', () {
      final rates = wholeSchedule();
      rates.first.unreadable.add('Employee %');

      expect(rateTableProblem(rates), contains('Employee %'));
      expect(rateTableProblem(rates), contains('not a number'));
    });

    test('and so does an unreadable employer rate', () {
      final rates = wholeSchedule();
      rates.last.unreadable.add('Employer %');

      expect(rateTableProblem(rates), contains('Employer %'));
    });

    test('it is refused before the arithmetic, not after', () {
      // A band with an unreadable box usually has bad numbers too --
      // `_read` leaves the previous value in place, so the band no
      // longer lines up with its neighbours. If the contiguity check
      // ran first the message would be about a gap, which tells the
      // person nothing about the box they are looking at.
      final rates = [
        band(from: 0, to: 5000),
        band(from: 9999),
      ];
      rates.last.unreadable.add('From');

      final problem = rateTableProblem(rates);
      expect(problem, contains('From'));
      expect(problem, isNot(contains('gap or overlap')));
    });

    test('both boxes are named when both are wrong', () {
      final rates = wholeSchedule();
      // Added in the order the boxes sit in the row, which is the order
      // somebody types them. A set keeps insertion order, so a version
      // that reported them unsorted would look correct here unless the
      // two orders differ -- they do, this way round.
      rates.first.unreadable.add('Employee %');
      rates.first.unreadable.add('Employer %');

      final problem = rateTableProblem(rates)!;
      expect(problem, contains('Employee %'));
      expect(problem, contains('Employer %'));
      // Sorted, so the same two bad boxes always produce the same
      // sentence rather than one that moves between rebuilds.
      expect(
        problem.indexOf('Employee %'),
        lessThan(problem.indexOf('Employer %')),
      );
    });

    test('a schedule with every box read is not stopped by this', () {
      // The control. Without it every assertion above passes against a
      // function that refuses everything.
      final rates = wholeSchedule();
      for (final r in rates) {
        expect(r.unreadable, isEmpty);
      }

      expect(rateTableProblem(rates), isNull);
    });

    group('as the box is typed into', () {
      /// The four boxes, each with what an empty one means.
      double? apply(RateDraft rate, String field, String raw) {
        double? seen;
        var called = false;
        readRateField(rate, field, raw, (n) {
          seen = n;
          called = true;
        });
        return called ? seen : double.nan;
      }

      test('a figure is read and the box is clean', () {
        final rate = band();
        expect(apply(rate, 'Employee %', '11.5'), 11.5);
        expect(rate.unreadable, isEmpty);
      });

      test('the per-cent sign the label asks for does not break it', () {
        // The box is labelled "Employee %". Typing the sign back into
        // it is the obvious thing to do, and it used to publish a
        // schedule that deducted nothing from that band.
        final rate = band();
        expect(apply(rate, 'Employee %', '11.5%'), 11.5);
        expect(rate.unreadable, isEmpty);
      });

      test('text that is not a figure is refused, not zeroed', () {
        final rate = band(employee: 0.11);
        final result = apply(rate, 'Employee %', '11,5');

        // `apply` was never called: nothing was written.
        expect(result, isNaN);
        expect(rate.unreadable, contains('Employee %'));
        // And the previous value is untouched, rather than cleared to
        // the nought this whole exercise is about.
        expect(rate.employeeRate, 0.11);
      });

      test('emptying the box clears the complaint', () {
        final rate = band();
        apply(rate, 'Employee %', 'not a number');
        expect(rate.unreadable, isNotEmpty);

        expect(apply(rate, 'Employee %', ''), isNull);
        expect(rate.unreadable, isEmpty);
      });

      test('and so does correcting it', () {
        final rate = band();
        apply(rate, 'From', 'five thousand');
        expect(rate.unreadable, contains('From'));

        expect(apply(rate, 'From', '5,000'), 5000);
        expect(rate.unreadable, isEmpty);
      });

      test('each box is remembered separately', () {
        // One bad box must not clear another's complaint, or correcting
        // the second would publish while the first is still wrong.
        final rate = band();
        apply(rate, 'Employee %', 'x');
        apply(rate, 'Employer %', 'y');
        expect(rate.unreadable, {'Employee %', 'Employer %'});

        apply(rate, 'Employer %', '13');
        expect(rate.unreadable, {'Employee %'});
      });
    });

    test('and a nought typed on purpose is still a nought', () {
      // The distinction the whole thing rests on. An empty box clears
      // the flag rather than setting it, so a band that genuinely
      // contributes nothing stays publishable.
      final rates = [band(from: 0, to: 10, employee: 0, employer: 0),
                     band(from: 10.01)];

      expect(rateTableProblem(rates), isNull);
    });
  });
}
