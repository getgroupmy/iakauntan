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
    bool floorApplies = true,
    bool actualKnown = true,
    bool revisionOpen = false,
    double? penalty = 0,
    String form = 'CP204',
  }) => TaxEstimateExposure(
    form: form,
    estimatedTax: estimated,
    priorEstimate: floorKnown ? 70000 : null,
    floorRequired: floorKnown ? 59500 : null,
    meetsFloor: meetsFloor,
    floorKnown: floorKnown,
    floorApplies: floorApplies,
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

  group('a floor that does not exist is not a floor that was missed', () {
    test('a CP204 below the floor misses it', () {
      expect(exposure(meetsFloor: false).missesFloor, isTrue);
    });

    test('a CP204 above it does not', () {
      expect(exposure().missesFloor, isFalse);
    });

    test('a CP204 whose prior year is unknown does not either', () {
      // `meetsFloor` is false here too, and reporting that as a
      // failure would be a red mark against a figure nobody has
      // checked.
      expect(
        exposure(floorKnown: false, meetsFloor: false).missesFloor,
        isFalse,
      );
    });

    test('and a CP500 never does, because it has no floor', () {
      // THE distinction. LHDN issues a CP500 from the preceding
      // assessment rather than the taxpayer proposing a figure, so
      // there is nothing to fall short of. `meetsFloor` is false for
      // a CP500 as well — which is why the screen switches on
      // `missesFloor` rather than on `!meetsFloor`.
      final e = exposure(
        form: 'CP500',
        floorApplies: false,
        floorKnown: false,
        meetsFloor: false,
      );
      expect(e.meetsFloor, isFalse);
      expect(e.missesFloor, isFalse);
      expect(e.floorApplies, isFalse);
    });

    test('even with last year''s figure sitting on the row', () {
      expect(
        exposure(form: 'CP500', floorApplies: false, meetsFloor: false)
            .missesFloor,
        isFalse,
      );
    });
  });

  group('a first basis period', () {
    TaxFirstPeriod first({
      bool isFirst = true,
      bool dueKnown = true,
      bool exempt = false,
      bool known = true,
      DateTime? due,
      DateTime? ordinary,
      // `due: null` cannot say "no deadline" through a `??` default,
      // so the absence needs its own switch. Written this way round
      // because the default IS a date for almost every case.
      bool noDue = false,
    }) => TaxFirstPeriod(
      isFirstPeriod: isFirst,
      form: 'CP204',
      commencedOn: DateTime(2026, 9, 15),
      filingDue: noDue ? null : (due ?? DateTime(2026, 12, 14)),
      ordinaryFilingDue: ordinary ?? DateTime(2025, 12, 2),
      filingDueKnown: dueKnown,
      exemptInstalments: exempt,
      exemptionKnown: known,
      exemptUntilYa: exempt ? 2027 : null,
      paidUpCapital: known ? 500000 : null,
      grossBusinessIncome: known ? 1200000 : null,
      capitalLimit: 2500000,
      turnoverLimit: 50000000,
    );

    test('an untested exemption is not a failed one', () {
      // The state worth asking about. Both mean "instalments are
      // scheduled", and only one of them means somebody checked.
      expect(first(known: false).exemptionUntested, isTrue);
      expect(first(known: false).exemptInstalments, isFalse);
    });

    test('a tested one is not untested, whichever way it went', () {
      expect(first(known: true, exempt: true).exemptionUntested, isFalse);
      expect(first(known: true, exempt: false).exemptionUntested, isFalse);
    });

    test('and an ordinary company has no untested exemption at all', () {
      // Not a first period: the question does not arise, and showing
      // "we could not check" to a fifteen-year-old company would be
      // asking it about a relief it cannot have.
      expect(first(isFirst: false, known: false).exemptionUntested, isFalse);
    });

    test('the ordinary deadline has usually already passed', () {
      // Which is why both dates are shown. A company incorporated in
      // September is being measured against a date thirty days before
      // the January its year opened.
      expect(first().ordinaryDateHasPassed, isTrue);
    });

    test('but not when it has not', () {
      expect(
        first(
          due: DateTime(2026, 3, 31),
          ordinary: DateTime(2026, 6, 1),
        ).ordinaryDateHasPassed,
        isFalse,
      );
    });

    test('and not when there is no real deadline to compare it with', () {
      // Nobody has said when the business commenced, so there is
      // nothing for the ordinary date to have passed BEFORE.
      expect(
        first(dueKnown: false, noDue: true).ordinaryDateHasPassed,
        isFalse,
      );
    });

    test('every first-period figure lands in its own field', () {
      final fp = TaxFirstPeriod.fromMap(const {
        'is_first_period': true,
        'form': 'CP204',
        'commenced_on': '2026-09-15',
        'filing_due': '2026-12-14',
        'ordinary_filing_due': '2025-12-02',
        'filing_due_known': true,
        'exempt_instalments': true,
        'exemption_known': true,
        'exempt_until_ya': 2027,
        'paid_up_capital': 500000,
        'gross_business_income': 1200000,
        'capital_limit': 2500000,
        'turnover_limit': 50000000,
      });

      expect(fp.isFirstPeriod, isTrue);
      expect(fp.commencedOn, DateTime(2026, 9, 15));
      expect(fp.filingDue, DateTime(2026, 12, 14));
      expect(fp.ordinaryFilingDue, DateTime(2025, 12, 2));
      expect(fp.filingDueKnown, isTrue);
      expect(fp.exemptInstalments, isTrue);
      expect(fp.exemptionKnown, isTrue);
      expect(fp.exemptUntilYa, 2027);
      expect(fp.paidUpCapital, 500000);
      expect(fp.grossBusinessIncome, 1200000);
      expect(fp.capitalLimit, 2500000);
      expect(fp.turnoverLimit, 50000000);
      expect(fp.ordinaryDateHasPassed, isTrue);
      expect(fp.exemptionUntested, isFalse);
    });

    test('an untested one comes back with nulls, not zeroes', () {
      // `Fmt.toDouble(null)` is 0, and a paid-up capital of zero would
      // pass the SME test on a figure nobody supplied.
      final fp = TaxFirstPeriod.fromMap(const {
        'is_first_period': true,
        'form': 'CP204',
        'filing_due_known': false,
        'exempt_instalments': false,
        'exemption_known': false,
      });
      expect(fp.paidUpCapital, isNull);
      expect(fp.grossBusinessIncome, isNull);
      expect(fp.exemptUntilYa, isNull);
      expect(fp.filingDue, isNull);
      expect(fp.exemptionUntested, isTrue);
      expect(fp.ordinaryDateHasPassed, isFalse);
    });

    test('an ordinary estimate reads as not a first period', () {
      final fp = TaxFirstPeriod.fromMap(const {});
      expect(fp.isFirstPeriod, isFalse);
      expect(fp.form, 'CP204');
      expect(fp.exemptInstalments, isFalse);
      expect(fp.exemptionKnown, isFalse);
      expect(fp.exemptionUntested, isFalse);
    });
  });

  group('reading the server back', () {
    test('every exposure figure lands in its own field', () {
      // Different numbers in every position, so a transposition
      // between two of them cannot pass.
      final e = TaxEstimateExposure.fromMap(const {
        'form': 'CP204',
        'estimated_tax': 60000,
        'prior_estimate': 70000,
        'floor_required': 59500,
        'meets_floor': true,
        'floor_known': true,
        'floor_applies': true,
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
      expect(e.form, 'CP204');
      expect(e.meetsFloor, isTrue);
      expect(e.floorKnown, isTrue);
      expect(e.floorApplies, isTrue);
      expect(e.missesFloor, isFalse);
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
      expect(e.floorApplies, isFalse);
      expect(e.missesFloor, isFalse);
      expect(e.isExposed, isFalse);
    });

    test('a CP500 comes back saying which form it is', () {
      final e = TaxEstimateExposure.fromMap(const {
        'form': 'CP500',
        'estimated_tax': 30000,
        'floor_known': false,
        'floor_applies': false,
        'meets_floor': false,
        'actual_known': false,
        'revision_open': false,
        'revision_months': [6],
      });
      expect(e.form, 'CP500');
      expect(e.floorApplies, isFalse);
      expect(e.missesFloor, isFalse);
      expect(e.revisionMonths, [6]);
    });

    test('a company whose prior year is unknown HAS a floor', () {
      // The one row where the two flags differ, and the only thing
      // that tells `floorApplies` apart from `floorKnown` at all: a
      // CP204 in its first year here has a floor that cannot yet be
      // checked. Reading one from the other would make that
      // indistinguishable from a CP500, which has no floor to check.
      final e = TaxEstimateExposure.fromMap(const {
        'form': 'CP204',
        'estimated_tax': 60000,
        'floor_applies': true,
        'floor_known': false,
        'meets_floor': false,
        'actual_known': false,
        'revision_open': false,
        'revision_months': [6, 9],
      });
      expect(e.floorApplies, isTrue);
      expect(e.floorKnown, isFalse);
      expect(e.missesFloor, isFalse);
    });

    test('a row that says nothing about the form reads as CP204', () {
      // The company form, which is what this product mostly holds —
      // and wrong in the direction that shows up as twelve dates
      // rather than six silent ones.
      final e = TaxEstimateExposure.fromMap(const {'estimated_tax': 1});
      expect(e.form, 'CP204');
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
        'set_by_revision': true,
      });
      expect(i.number, 7);
      expect(i.dueOn, DateTime(2026, 8, 15));
      expect(i.amount, 5001.25);
      expect(i.setByRevision, isTrue);
      expect(i.isWaived, isFalse);
    });

    test('an instalment the original set is not marked revised', () {
      final i = TaxInstalment.fromMap(const {
        'instalment_no': 1,
        'due_on': '2026-02-15',
        'amount': 10000,
        'set_by_revision': false,
      });
      expect(i.setByRevision, isFalse);
      expect(i.isWaived, isFalse);
    });

    test('a row that says nothing about it reads as the original', () {
      // The safe direction: an unrevised schedule is the ordinary
      // case, and marking every row "revised" would make the flag
      // useless on the screens where it matters.
      final i = TaxInstalment.fromMap(const {
        'instalment_no': 1,
        'amount': 10000,
      });
      expect(i.setByRevision, isFalse);
    });

    test('a revised instalment reduced to nothing is waived', () {
      // A downward revision leaves the remaining instalments at nil.
      // Distinct from an estimate of zero, where nothing was ever
      // payable — the year owes less than has been billed and the
      // excess comes back at assessment.
      final i = TaxInstalment.fromMap(const {
        'instalment_no': 9,
        'due_on': '2026-10-15',
        'amount': 0,
        'set_by_revision': true,
      });
      expect(i.isWaived, isTrue);
    });

    test('but an original instalment of nothing is not waived', () {
      // An estimate of nothing gives twelve instalments of nothing,
      // and calling those "waived" would claim a revision that never
      // happened.
      final i = TaxInstalment.fromMap(const {
        'instalment_no': 1,
        'due_on': '2026-02-15',
        'amount': 0,
        'set_by_revision': false,
      });
      expect(i.isWaived, isFalse);
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
