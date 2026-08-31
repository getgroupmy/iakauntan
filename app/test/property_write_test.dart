import 'package:flutter_test/flutter_test.dart';
import 'package:iakauntan/src/features/property/statutory_charge_sheet.dart';
import 'package:iakauntan/src/features/property/strata_sheet.dart';
import 'package:iakauntan/src/features/property/tenancy_sheet.dart';
import 'package:iakauntan/src/features/property/unit_sheet.dart';

/// Writing to the property module, which nothing could.
///
/// `0162` has had the tables, the triggers and the exclusion constraint
/// since the module went in, and until now nothing called any of it: a
/// managing agent could read a Schedule of Parcels and had no way to
/// enter one, and a strata scheme could never levy a Charge because the
/// rate an AGM resolved had nowhere to go.
///
/// What is pressed here is the shape of what gets written, because the
/// rules are triggers and CHECK constraints: send the wrong shape and
/// the insert is refused with a sentence about a constraint, which is
/// true and no help at all to the person who typed it.
void main() {
  group('what a unit can be, given what the site is', () {
    test('a strata scheme holds parcels, not shophouses', () {
      // `app.property_unit_matches_site` refuses the pairing outright.
      // Offering only what the tenure allows means the refusal never
      // has to happen.
      expect(unitTypesFor('strata'), ['parcel', 'accessory', 'common']);
      expect(unitTypesFor('strata'), isNot(contains('shop')));
    });

    test('and a row of shophouses holds no parcels', () {
      for (final tenure in ['freehold', 'leasehold']) {
        expect(unitTypesFor(tenure), isNot(contains('parcel')), reason: tenure);
        expect(unitTypesFor(tenure), isNot(contains('accessory')),
            reason: tenure);
        expect(unitTypesFor(tenure), contains('shop'), reason: tenure);
      }
    });

    test('every type offered has words for it', () {
      for (final t in [...unitTypesFor('strata'), ...unitTypesFor('freehold')]) {
        expect(unitTypeNames[t], isNotNull, reason: t);
      }
    });
  });

  group('the share units a parcel is charged on', () {
    test('a chargeable parcel needs its share', () {
      // The one that would otherwise be found at the AGM: billing a
      // parcel with no allocated share units means somebody else is
      // paying for it.
      expect(needsShareUnits('strata', 'parcel', true), isTrue);
    });

    test('a parcel the scheme does not levy on does not', () {
      expect(needsShareUnits('strata', 'parcel', false), isFalse);
    });

    test('and nothing on a non-strata site does', () {
      expect(needsShareUnits('freehold', 'shop', true), isFalse);
      expect(needsShareUnits('leasehold', 'landed', true), isFalse);
    });

    test('share units typed before the tenure was understood are dropped', () {
      // 'Share units belong to a strata scheme' -- the trigger's words.
      // A figure carried over onto a shophouse is refused outright, so
      // it is dropped rather than sent.
      final v = unitValues(
        siteId: 's', tenure: 'freehold',
        unitNo: '12', unitType: 'shop', shareUnits: 140,
      );
      expect(v['share_units'], isNull);
    });

    test('and kept on a parcel', () {
      final v = unitValues(
        siteId: 's', tenure: 'strata',
        unitNo: 'A-12-03', unitType: 'parcel', shareUnits: 140,
      );
      expect(v['share_units'], 140);
    });

    test('fractions survive, because rounding them moves money', () {
      // Some schedules allocate fractions. A parcel rounded down pays
      // less than its share and its neighbours make up the difference.
      expect(shareUnitsOf('140.5625'), 140.5625);
    });

    test('a negative share is not a share', () {
      expect(shareUnitsOf('-1'), isNull);
      expect(shareUnitsOf('nought'), isNull);
    });

    test('but nought is, because a parcel can carry none', () {
      // Common property and anything non-chargeable. This is the one
      // character that separates `shareUnitsOf` from
      // `totalShareUnitsOf` below, and the two sit in different files.
      expect(shareUnitsOf('0'), 0);
    });
  });

  group('the denominator of the Schedule of Parcels', () {
    test('is the figure the schedule states', () {
      expect(totalShareUnitsOf('1000'), 1000);
      expect(totalShareUnitsOf('  281.125 '), 281.125);
    });

    test('and may not be nought, where a parcel may', () {
      // Every share in the scheme is `share_units / total_share_units`.
      // A zero denominator is not a scheme with nothing allocated — it
      // is a division nobody can do, and the sheet has to refuse it
      // before it reaches the apportionment rather than after.
      expect(totalShareUnitsOf('0'), isNull);
      expect(totalShareUnitsOf('-1'), isNull);
    });

    test('a schedule nobody has entered yet is absent, not nought', () {
      // Null is "not stated". `scheduleIsComplete` reads it as
      // incomplete, which is a different answer from a scheme whose
      // parcels genuinely add to nothing.
      expect(totalShareUnitsOf(''), isNull);
      expect(totalShareUnitsOf('   '), isNull);
      expect(totalShareUnitsOf('the whole block'), isNull);
    });
  });

  group('the floor area of a parcel', () {
    test('is what was measured', () {
      expect(sqftOf('1250'), 1250);
      expect(sqftOf(' 980.5 '), 980.5);
    });

    test('and a parcel of no area is not a parcel', () {
      // Unlike share units, where nought is a real allocation. Area is
      // the thing that exists.
      expect(sqftOf('0'), isNull);
      expect(sqftOf('-40'), isNull);
    });

    test('while one nobody has measured is simply unknown', () {
      expect(sqftOf(''), isNull);
      expect(sqftOf('   '), isNull);
    });
  });

  group('what common property is', () {
    test('never billed, and has no owner to bill', () {
      // The failure this exists for: common property entered with the
      // owner still selected from the parcel before it, and then
      // invoiced to a resident who does not own the lifts.
      final v = unitValues(
        siteId: 's', tenure: 'strata',
        unitNo: 'CP-1', unitType: 'common',
        ownerContactId: 'someone', isChargeable: true, shareUnits: 10,
      );
      expect(v['owner_contact_id'], isNull);
      expect(v['is_chargeable'], isFalse);
      expect(v['share_units'], isNull);
    });
  });

  group('what an accessory parcel hangs off', () {
    test('a principal, and only when it is accessory', () {
      final v = unitValues(
        siteId: 's', tenure: 'strata', unitNo: 'CP-14',
        unitType: 'accessory', principalUnitId: 'parcel-1',
      );
      expect(v['principal_unit_id'], 'parcel-1');
    });

    test('and a principal left over on a parcel is dropped', () {
      final v = unitValues(
        siteId: 's', tenure: 'strata', unitNo: 'A-12-03',
        unitType: 'parcel', principalUnitId: 'parcel-1', shareUnits: 140,
      );
      expect(v['principal_unit_id'], isNull);
    });
  });

  group('the deposit a tenancy holds', () {
    test('on the day it is written, held is what was taken', () {
      // Agreed and held are separate columns because they part company
      // later. Asking for both on day one is how they come to disagree
      // on day one.
      expect(depositHeldFor(2400, 600), 3000);
      final v = tenancyValues(
        unitId: 'u', tenantContactId: 'c', tenancyNo: 'T-001',
        startDate: DateTime(2026, 1, 1), endDate: DateTime(2026, 12, 31),
        monthlyRent: 1200, rentDueDay: 1,
        securityDeposit: 2400, utilityDeposit: 600,
      );
      expect(v['deposit_held'], 3000);
    });

    test('and an amendment says what is held now', () {
      // A deposit part-forfeited on exit does not change the agreement.
      final v = tenancyValues(
        unitId: 'u', tenantContactId: 'c', tenancyNo: 'T-001',
        startDate: DateTime(2026, 1, 1), endDate: DateTime(2026, 12, 31),
        monthlyRent: 1200, rentDueDay: 1,
        securityDeposit: 2400, utilityDeposit: 600, depositHeld: 1800,
      );
      expect(v['security_deposit'], 2400);
      expect(v['deposit_held'], 1800);
    });

    test('the sum is rounded to the sen', () {
      expect(depositHeldFor(0.1, 0.2), 0.30);
    });
  });

  group('when the rent falls due', () {
    test('the 28th is the last day a month always has', () {
      // A tenancy falling due on the 31st has no due date in February,
      // and February is the month the tenant is chased for.
      expect(rentDueDayOf('28'), 28);
      expect(rentDueDayOf('29'), isNull);
      expect(rentDueDayOf('31'), isNull);
      expect(rentDueDayOf('0'), isNull);
    });
  });

  group('the days a tenancy runs', () {
    test('it cannot expire before it commences', () {
      expect(datesRun(DateTime(2026, 6, 1), DateTime(2026, 5, 31)), isFalse);
    });

    test('a single day is a tenancy', () {
      expect(datesRun(DateTime(2026, 6, 1), DateTime(2026, 6, 1)), isTrue);
    });

    test('a tenancy still being drawn up is not one', () {
      expect(datesRun(null, DateTime(2026, 6, 1)), isFalse);
      expect(datesRun(DateTime(2026, 6, 1), null), isFalse);
    });
  });

  group('which tenancies hold the unit', () {
    test('draft and active both do', () {
      // `tenancies_no_overlap` covers both, and rightly: a draft
      // tenancy is one the landlord has agreed and not commenced, and
      // letting the same unit over the same days is the double booking
      // the constraint exists to prevent.
      expect(tenancyHoldsUnit('draft'), isTrue);
      expect(tenancyHoldsUnit('active'), isTrue);
    });

    test('and a tenancy that has ended does not', () {
      expect(tenancyHoldsUnit('expired'), isFalse);
      expect(tenancyHoldsUnit('terminated'), isFalse);
    });
  });

  group('a termination date', () {
    test('belongs to a terminated tenancy', () {
      final v = tenancyValues(
        unitId: 'u', tenantContactId: 'c', tenancyNo: 'T-001',
        startDate: DateTime(2026, 1, 1), endDate: DateTime(2026, 12, 31),
        monthlyRent: 1200, rentDueDay: 1,
        status: 'terminated', terminatedOn: DateTime(2026, 6, 30),
      );
      expect(v['terminated_on'], '2026-06-30');
    });

    test('and not to one that is still running', () {
      // A date for something that did not happen. The failure this
      // exists for: a date picked while considering a termination, then
      // the status left active, and the tenancy reading as ended in
      // every report that looks at the date.
      final v = tenancyValues(
        unitId: 'u', tenantContactId: 'c', tenancyNo: 'T-001',
        startDate: DateTime(2026, 1, 1), endDate: DateTime(2026, 12, 31),
        monthlyRent: 1200, rentDueDay: 1,
        status: 'active', terminatedOn: DateTime(2026, 6, 30),
      );
      expect(v['terminated_on'], isNull);
    });
  });

  group('what the scheme is', () {
    test('a registration number belongs to a management corporation', () {
      // A JMB is not registered. A number carried over from a template
      // asserts a registration that does not exist.
      final mc = strataSchemeValues(
        siteId: 's', stage: 'mc', mcRegistrationNo: 'MC-12345',
      );
      expect(mc['mc_registration_no'], 'MC-12345');

      for (final stage in ['jmb', 'developer']) {
        final v = strataSchemeValues(
          siteId: 's', stage: stage, mcRegistrationNo: 'MC-12345',
        );
        expect(v['mc_registration_no'], isNull, reason: stage);
      }
    });

    test('every stage has words for it', () {
      for (final s in ['developer', 'jmb', 'mc']) {
        expect(strataStageNames[s], isNotNull, reason: s);
      }
    });

    test('a blank reference is null rather than an empty string', () {
      final v = strataSchemeValues(
        siteId: 's', stage: 'jmb', cobReference: '   ',
      );
      expect(v['cob_reference'], isNull);
    });
  });

  group('whether the Schedule of Parcels adds up', () {
    test('it does when the parcels reach the stated total', () {
      expect(scheduleIsComplete(1000, 1000), isTrue);
    });

    test('and it does not when half of them are still to be entered', () {
      // Held separately rather than summed so a half-entered schedule
      // is visibly incomplete instead of silently changing everyone's
      // share of the Charges.
      expect(scheduleIsComplete(1000, 540), isFalse);
    });

    test('fractions that add up are complete', () {
      expect(scheduleIsComplete(140.5625 * 2, 281.125), isTrue);
    });

    test('a scheme that has not stated a total is not complete', () {
      expect(scheduleIsComplete(null, 1000), isFalse);
    });
  });

  group('the rate an AGM resolved', () {
    test('the sinking fund floor is ten per cent', () {
      // s.25(3) for a JMB, s.51(2) for a management corporation. A
      // scheme may resolve to contribute more; it may not resolve to
      // contribute less.
      expect(percentOf('10', min: sinkingFundFloor, max: 100), 10);
      expect(percentOf('9.999', min: sinkingFundFloor, max: 100), isNull);
      expect(percentOf('35', min: sinkingFundFloor, max: 100), 35);
    });

    test('the late payment charge is capped at ten per cent a year', () {
      // Third Schedule, Strata Management (Maintenance and Management)
      // Regulations 2015.
      expect(percentOf('10', min: 0, max: lateInterestCeiling), 10);
      expect(percentOf('10.001', min: 0, max: lateInterestCeiling), isNull);
      expect(percentOf('0', min: 0, max: lateInterestCeiling), 0);
    });

    test('a rate of nothing is a resolution to charge nothing', () {
      // Which a scheme between rates may well have passed.
      expect(rateOf('0'), 0);
      expect(rateOf('-0.5'), isNull);
    });

    test('the whole resolution reaches its own columns', () {
      final v = chargeRateValues(
        effectiveFrom: DateTime(2026, 1, 1),
        ratePerShareUnit: 0.3350,
        sinkingFundPercent: 12,
        lateInterestPercent: 8,
        resolutionReference: 'AGM 2025/3',
      );
      expect(v['effective_from'], '2026-01-01');
      expect(v['rate_per_share_unit'], 0.3350);
      expect(v['sinking_fund_percent'], 12);
      expect(v['late_interest_percent'], 8);
      expect(v['resolution_reference'], 'AGM 2025/3');
    });

    test('a rate left at the defaults is at the floor and the cap', () {
      final v = chargeRateValues(
        effectiveFrom: DateTime(2026, 1, 1), ratePerShareUnit: 0.30,
      );
      expect(v['sinking_fund_percent'], 10);
      expect(v['late_interest_percent'], 10);
    });
  });

  group('quit rent and assessment', () {
    test('assessment is half-yearly and quit rent is not', () {
      expect(hasHalves('assessment'), isTrue);
      expect(hasHalves('quit_rent'), isFalse);
    });

    test('a half on a quit rent is a period that does not exist', () {
      // And the unique key counts it as a different charge, which is
      // how the same year gets entered twice.
      final v = statutoryChargeValues(
        siteId: 's', kind: 'quit_rent', periodYear: 2026, periodHalf: 1,
        amount: 480, dueDate: DateTime(2026, 5, 31),
      );
      expect(v['period_half'], isNull);
    });

    test('and an assessment keeps its half', () {
      final v = statutoryChargeValues(
        siteId: 's', kind: 'assessment', periodYear: 2026, periodHalf: 2,
        amount: 320, dueDate: DateTime(2026, 8, 31),
      );
      expect(v['period_half'], 2);
    });

    test('a payment reference for an unpaid bill refers to nothing', () {
      final v = statutoryChargeValues(
        siteId: 's', kind: 'assessment', periodYear: 2026, periodHalf: 1,
        amount: 320, dueDate: DateTime(2026, 2, 28), reference: 'CHQ-9001',
      );
      expect(v['reference'], isNull);
      expect(v['paid_on'], isNull);
    });

    test('and a paid one keeps it', () {
      final v = statutoryChargeValues(
        siteId: 's', kind: 'assessment', periodYear: 2026, periodHalf: 1,
        amount: 320, dueDate: DateTime(2026, 2, 28),
        paidOn: DateTime(2026, 2, 20), reference: 'CHQ-9001',
      );
      expect(v['paid_on'], '2026-02-20');
      expect(v['reference'], 'CHQ-9001');
    });

    test('a year outside living memory is a typing slip', () {
      expect(yearOf('2026'), 2026);
      expect(yearOf('26'), isNull);
      expect(yearOf('20260'), isNull);
    });

    test('an amount of nothing is a bill of nothing, which happens', () {
      expect(amountOf('0'), 0);
      expect(amountOf('1,250.50'), 1250.50);
      expect(amountOf('-5'), isNull);
    });
  });
}
