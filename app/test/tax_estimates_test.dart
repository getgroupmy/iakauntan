import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/data/models.dart';

/// The Dart side of CP204.
///
/// The arithmetic — the floor, the tolerance, the tenth of the excess,
/// the instalment cast — is in SQL and asserted in
/// `supabase/tests/tax_estimates.sql`. What is asserted here is what
/// the SCREEN decides, and every one of those decisions is about
/// telling "not yet known" apart from "nothing to worry about":
///
///   * **Unknown is not safe.** For most of the year there is no
///     computation to measure against. A screen that read a missing
///     penalty as zero would show a green tick to a company heading
///     for one, all the way up to the month the revision window shuts.
///   * **Exposed is not the same as fixable.** Money at stake in month
///     eleven is a fact to record. Money at stake in month six is a
///     thing somebody can still do something about, and that is the
///     only state worth interrupting them for.
///   * **A floor nobody has checked is not a floor that was cleared.**
void main() {
  TaxEstimateExposure exposure({
    double estimated = 60000,
    bool floorKnown = true,
    bool meetsFloor = true,
    bool actualKnown = true,
    bool revisionOpen = false,
    double? penalty = 0,
  }) => TaxEstimateExposure(
    estimatedTax: estimated,
    priorEstimate: floorKnown ? 70000 : null,
    floorRequired: floorKnown ? 59500 : null,
    meetsFloor: meetsFloor,
    floorKnown: floorKnown,
    actualTax: actualKnown ? 90000 : null,
    actualKnown: actualKnown,
    shortfall: actualKnown ? 30000 : null,
    toleranceAmount: actualKnown ? 27000 : null,
    excessOverTolerance: actualKnown ? 3000 : null,
    penalty: penalty,
    revisionOpen: revisionOpen,
    revisionMonths: const [6, 9],
  );

  group('whether there is anything to worry about', () {
    test('a penalty means exposed', () {
      expect(exposure(penalty: 300).isExposed, isTrue);
    });

    test('a penalty of nothing does not', () {
      expect(exposure(penalty: 0).isExposed, isFalse);
    });

    test('and neither does a year nobody can measure yet', () {
      // The trap this exists for. `actualKnown` false is most of the
      // year, and a null penalty read as zero would be indistinguishable
      // from a company that estimated correctly.
      expect(
        exposure(actualKnown: false, penalty: null).isExposed,
        isFalse,
      );
    });

    test('and a measured year with no penalty figure is not exposed', () {
      // The other way round: known, but priced at null. The server
      // prices every measured year, so this too asserts the intent --
      // and the direction matters, because the screen prints
      // `penalty ?? 0` and would otherwise raise an alarm reading
      // "RM 0.00 of penalty".
      expect(exposure(penalty: null).isExposed, isFalse);
      expect(exposure(penalty: null, revisionOpen: true).canStillFix,
          isFalse);
    });

    test('not even if a penalty figure somehow came back with it', () {
      // The server does not produce this today — no computation means
      // no shortfall to price. The predicate's INTENT is that an
      // unmeasured year is never reported as exposed, whatever else
      // is in the row.
      expect(
        exposure(actualKnown: false, penalty: 5000).isExposed,
        isFalse,
      );
    });
  });

  group('whether it can still be fixed', () {
    test('exposed in a revision month is the one state worth shouting', () {
      final e = exposure(penalty: 300, revisionOpen: true);
      expect(e.isExposed, isTrue);
      expect(e.canStillFix, isTrue);
    });

    test('exposed outside one is a fact, not an action', () {
      expect(exposure(penalty: 300).canStillFix, isFalse);
    });

    test('and a revision month with nothing at stake is not an alarm', () {
      // Month six of a year that is estimated correctly. The window
      // being open is not by itself news.
      expect(exposure(penalty: 0, revisionOpen: true).canStillFix, isFalse);
    });

    test('nor is a revision month in a year nobody can measure', () {
      expect(
        exposure(actualKnown: false, penalty: null, revisionOpen: true)
            .canStillFix,
        isFalse,
      );
    });
  });

  group('reading the server back', () {
    test('every exposure figure lands in its own field', () {
      // Different numbers in every position, so a transposition
      // between two of them cannot pass.
      final e = TaxEstimateExposure.fromMap(const {
        'estimated_tax': 60000,
        'prior_estimate': 70000,
        'floor_required': 59500,
        'meets_floor': true,
        'floor_known': true,
        'actual_tax': 91000,
        'actual_known': true,
        'shortfall': 31000,
        'tolerance_amount': 27300,
        'excess_over_tolerance': 3700,
        'penalty': 370,
        'revision_open': true,
        'revision_months': [6, 9],
      });

      expect(e.estimatedTax, 60000);
      expect(e.priorEstimate, 70000);
      expect(e.floorRequired, 59500);
      expect(e.meetsFloor, isTrue);
      expect(e.floorKnown, isTrue);
      expect(e.actualTax, 91000);
      expect(e.shortfall, 31000);
      expect(e.toleranceAmount, 27300);
      expect(e.excessOverTolerance, 3700);
      expect(e.penalty, 370);
      expect(e.revisionMonths, [6, 9]);
      expect(e.isExposed, isTrue);
      expect(e.canStillFix, isTrue);
    });

    test('a null penalty stays null rather than becoming zero', () {
      // `Fmt.toDouble(null)` is 0, so the null checks in `fromMap` are
      // what keeps "not yet known" distinguishable from "nothing owed"
      // — and the screen prints the two differently.
      final e = TaxEstimateExposure.fromMap(const {
        'estimated_tax': 60000,
        'floor_known': false,
        'actual_known': false,
        'revision_open': false,
        'revision_months': [6, 9],
      });

      expect(e.penalty, isNull);
      expect(e.actualTax, isNull);
      expect(e.shortfall, isNull);
      expect(e.priorEstimate, isNull);
      expect(e.floorRequired, isNull);
      expect(e.floorKnown, isFalse);
      expect(e.meetsFloor, isFalse);
      expect(e.isExposed, isFalse);
    });

    test('a missing revision window is no months rather than a throw', () {
      final e = TaxEstimateExposure.fromMap(const {
        'estimated_tax': 1,
      });
      expect(e.revisionMonths, isEmpty);
      expect(e.revisionOpen, isFalse);
      expect(e.canStillFix, isFalse);
    });

    test('every instalment figure lands in its own field', () {
      final i = TaxInstalment.fromMap(const {
        'instalment_no': 7,
        'due_on': '2026-08-15',
        'amount': 5001.25,
      });
      expect(i.number, 7);
      expect(i.dueOn, DateTime(2026, 8, 15));
      expect(i.amount, 5001.25);
    });

    test('an instalment with no date reads as no date', () {
      final i = TaxInstalment.fromMap(const {
        'instalment_no': 1,
        'amount': 100,
      });
      expect(i.dueOn, isNull);
      expect(i.amount, 100);
    });
  });
}
