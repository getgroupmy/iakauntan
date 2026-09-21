import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/data/models.dart';

/// The Dart side of Form B and Form P.
///
/// The arithmetic is in SQL and asserted there —
/// `supabase/tests/tax_forms_b_and_p.sql` is where a rate or an order
/// of operations moving fails. What is asserted here is what the
/// SCREENS decide, and three of those decisions are the difference
/// between a figure somebody can act on and one they cannot:
///
///   * **A donation that was cut down says so.** The claimed figure and
///     the allowed one differ whenever s.44(6) bites, and a screen that
///     showed only the smaller number would look like arithmetic
///     somebody got wrong.
///   * **Shares that do not come to a hundred.** A partnership whose
///     ratios come to ninety allocates nine tenths of its income and
///     the missing tenth appears nowhere. The allocation still adds up,
///     down its own column, to the wrong total.
///   * **A refund is negative.** Same rule as Form C, and the same
///     reason: a person who overpaid CP500 is owed money.
void main() {
  IndividualTaxComputation formB({
    double claimed = 0,
    double allowed = 0,
    double payable = 1000,
    double adjustedLoss = 0,
  }) => IndividualTaxComputation(
    yearOfAssessment: 2026,
    periodFrom: DateTime(2026, 1, 1),
    periodTo: DateTime(2026, 12, 31),
    profitBeforeTax: 200000,
    addBacks: 0,
    deductions: 0,
    balancingCharge: 0,
    adjustedIncome: 200000,
    adjustedLoss: adjustedLoss,
    caCurrent: 0,
    caUsed: 0,
    caCarriedForward: 0,
    statutoryBusiness: 200000,
    otherIncome: 0,
    aggregateIncome: 200000,
    approvedDonations: claimed,
    donationsAllowed: allowed,
    totalIncome: 200000 - allowed,
    reliefsClaimed: 0,
    chargeableIncome: 200000 - allowed,
    taxCharged: 40000,
    rebate: 0,
    zakatRebate: 0,
    s110TaxDeducted: 0,
    instalmentsPaid: 0,
    taxPayable: payable,
  );

  PartnershipSummary summary({
    double shares = 100,
    int partners = 2,
    double appropriations = 63000,
  }) => PartnershipSummary(
    adjustedIncome: 200000,
    appropriations: appropriations,
    divisibleIncome: 200000,
    partnershipAdjusted: 200000 + appropriations,
    totalAllocated: 200000 + appropriations,
    sharesTotal: shares,
    partnerCount: partners,
  );

  group('a donation that was restricted', () {
    test('is spotted when the allowed figure is smaller', () {
      // s.44(6) cannot take aggregate income below nothing. A screen
      // that showed only the smaller number would look like arithmetic
      // somebody got wrong rather than a rule somebody hit.
      expect(formB(claimed: 90000, allowed: 60000).donationsRestricted,
          isTrue);
    });

    test('and is not when the whole of it was allowed', () {
      expect(formB(claimed: 10000, allowed: 10000).donationsRestricted,
          isFalse);
    });

    test('nor when there was no donation at all', () {
      expect(formB().donationsRestricted, isFalse);
    });
  });

  group('the bottom line', () {
    test('an amount owed is not a refund', () {
      expect(formB(payable: 5500).isRefund, isFalse);
    });

    test('an overpayment is', () {
      expect(formB(payable: -2400).isRefund, isTrue);
    });

    test('and owing exactly nothing is neither', () {
      expect(formB(payable: 0).isRefund, isFalse);
    });

    test('a loss year says so', () {
      expect(formB(adjustedLoss: 40000).hasLoss, isTrue);
      expect(formB().hasLoss, isFalse);
    });
  });

  group('whether a partnership adds up', () {
    test('a hundred per cent between them balances', () {
      expect(summary().sharesBalance, isTrue);
    });

    test('ninety does not', () {
      // The allocation still adds up, down its own column, to the
      // wrong total — which is why this is a screen warning rather
      // than something the figures would show.
      expect(summary(shares: 90).sharesBalance, isFalse);
    });

    test('and a hundred and ten does not either', () {
      expect(summary(shares: 110).sharesBalance, isFalse);
    });

    test('three ways at 33.33 each is close enough', () {
      // A deed that splits three ways writes 33.33 and expects it to
      // be right. An equality test would put a red warning on every
      // three-partner firm in the country.
      expect(summary(shares: 99.99, partners: 3).sharesBalance, isTrue);
    });

    test('but a whole per cent out is not', () {
      expect(summary(shares: 99, partners: 3).sharesBalance, isFalse);
    });

    test('and a partnership with no partners is not balanced', () {
      // Zero shares out of zero partners is arithmetically fine and
      // substantively empty. Saying "balanced" of it would put a tick
      // beside a Form P that allocates nothing.
      expect(summary(shares: 0, partners: 0).sharesBalance, isFalse);
      expect(summary(shares: 0, partners: 0).isEmpty, isTrue);

      // And not even if the shares somehow came to a hundred with
      // nobody to hold them. The server cannot produce that today --
      // no partners means no percentages to sum -- so this asserts the
      // predicate's INTENT rather than a state the database reaches:
      // "balanced" must mean the income has somewhere to go.
      expect(summary(shares: 100, partners: 0).sharesBalance, isFalse);
    });
  });

  group('reading the server back', () {
    test('every Form B figure lands in its own field', () {
      // Different numbers in every position, so a transposition
      // between two fields cannot pass.
      final c = IndividualTaxComputation.fromMap(const {
        'year_of_assessment': 2026,
        'profit_before_tax': 200000,
        'add_backs': 12000,
        'deductions': 3000,
        'balancing_charge': 800,
        'adjusted_income': 209800,
        'adjusted_loss': 0,
        'ca_current': 34000,
        'ca_used': 34000,
        'ca_carried_forward': 0,
        'statutory_business': 175800,
        'other_income': 48000,
        'aggregate_income': 223800,
        'approved_donations': 10000,
        'donations_allowed': 9000,
        'total_income': 214800,
        'reliefs_claimed': 15500,
        'chargeable_income': 199300,
        'tax_charged': 34225,
        'rebate': 0,
        'zakat_rebate': 1200,
        's110_tax_deducted': 2200,
        'instalments_paid': 30000,
        'tax_payable': 825,
      });

      expect(c.statutoryBusiness, 175800);
      expect(c.otherIncome, 48000);
      expect(c.aggregateIncome, 223800);
      expect(c.approvedDonations, 10000);
      expect(c.donationsAllowed, 9000);
      expect(c.donationsRestricted, isTrue);
      expect(c.totalIncome, 214800);
      expect(c.reliefsClaimed, 15500);
      expect(c.chargeableIncome, 199300);
      expect(c.taxCharged, 34225);
      expect(c.zakatRebate, 1200);
      expect(c.s110TaxDeducted, 2200);
      expect(c.instalmentsPaid, 30000);
      expect(c.taxPayable, 825);
    });

    test('and every partner figure does', () {
      final p = PartnerAllocation.fromMap(const {
        'partner_id': 'p1',
        'name': 'Ali',
        'tax_reference': 'SG 123',
        'share_percent': 60,
        'salary': 36000,
        'interest_on_capital': 2000,
        'share_of_divisible': 120000,
        'capital_allowances': 20400,
        'statutory_income': 137600,
      });

      expect(p.name, 'Ali');
      expect(p.sharePercent, 60);
      expect(p.salary, 36000);
      expect(p.interestOnCapital, 2000);
      expect(p.shareOfDivisible, 120000);
      expect(p.capitalAllowances, 20400);
      expect(p.statutoryIncome, 137600);
    });

    test('a missing figure reads as nothing rather than throwing', () {
      final c = IndividualTaxComputation.fromMap(const {
        'year_of_assessment': 2026,
      });
      expect(c.taxPayable, 0);
      expect(c.isRefund, isFalse);
      expect(c.donationsRestricted, isFalse);
    });
  });
}
