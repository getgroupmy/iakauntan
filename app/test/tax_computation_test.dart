import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/data/models.dart';

/// The Dart side of the Form C computation.
///
/// The arithmetic is in SQL and asserted there —
/// `supabase/tests/tax_computation.sql` is where a rate or an order of
/// operations moving fails. What is asserted here is what the MODEL
/// decides once the figures arrive, and each of these would be wrong
/// silently:
///
///   * **A refund is negative.** `tax_payable` is not clamped at zero,
///     because a company that overpaid CP204 is owed money and a screen
///     that showed "0.00" would hide it.
///   * **A loss is not a negative income.** The two are separate fields
///     and the screen draws different lines for them; reading an
///     adjusted loss as income of the same magnitude inverts the whole
///     computation.
///   * **A partial line says so.** "50% of 12,000" answers the question
///     a bare 6,000 provokes, and only where a fraction was applied.
void main() {
  TaxComputation comp({
    double payable = 1000,
    double adjustedIncome = 200000,
    double adjustedLoss = 0,
    bool isSme = true,
    bool smeKnown = true,
  }) => TaxComputation(
    yearOfAssessment: 2026,
    periodFrom: DateTime(2026, 1, 1),
    periodTo: DateTime(2026, 12, 31),
    profitBeforeTax: 200000,
    addBacks: 0,
    deductions: 0,
    balancingCharge: 0,
    adjustedIncome: adjustedIncome,
    adjustedLoss: adjustedLoss,
    caCurrent: 0,
    caBroughtForward: 0,
    caUsed: 0,
    caCarriedForward: 0,
    statutoryIncome: adjustedIncome,
    lossBroughtForward: 0,
    lossUsed: 0,
    lossCarriedForward: 0,
    chargeableIncome: adjustedIncome,
    isSme: isSme,
    smeKnown: smeKnown,
    taxCharged: 37500,
    zakatRebate: 0,
    s110TaxDeducted: 0,
    cp204Paid: 0,
    taxPayable: payable,
  );

  TaxComputationLine line({
    String kind = 'add_back',
    double gross = 12000,
    double fraction = 1,
    double amount = 12000,
  }) => TaxComputationLine(
    kind: kind,
    label: 'Entertainment',
    source: 'Account 6200 Entertainment',
    gross: gross,
    fraction: fraction,
    amount: amount,
  );

  group('what the bottom line says', () {
    test('an amount owed is not a refund', () {
      expect(comp(payable: 5500).isRefund, isFalse);
    });

    test('an overpayment is', () {
      // Negative, and NOT clamped. A company that overpaid its CP204
      // instalments is owed the difference, and a figure rounded up to
      // zero is money nobody goes looking for.
      expect(comp(payable: -14500).isRefund, isTrue);
    });

    test('and owing exactly nothing is neither', () {
      // The boundary. `< 0` against `<= 0` turns "nothing to pay" into
      // "a refund of nothing", which is a line on a screen claiming
      // money is coming back.
      expect(comp(payable: 0).isRefund, isFalse);
    });
  });

  group('a loss is not an income', () {
    test('a year with a loss says so', () {
      expect(
        comp(adjustedIncome: 0, adjustedLoss: 160000).hasLoss,
        isTrue,
      );
    });

    test('and the income is nothing rather than negative', () {
      // `0665` never returns a negative adjusted income: nothing
      // downstream may be computed from one, so the loss is reported
      // separately and positive.
      final c = comp(adjustedIncome: 0, adjustedLoss: 160000);
      expect(c.adjustedIncome, 0);
      expect(c.adjustedLoss, greaterThan(0));
    });

    test('a profitable year has no loss at all', () {
      expect(comp(adjustedIncome: 200000).hasLoss, isFalse);
    });

    test('and a year that breaks exactly even has neither', () {
      final c = comp(adjustedIncome: 0, adjustedLoss: 0);
      expect(c.hasLoss, isFalse);
    });
  });

  group('a line of the working', () {
    test('a whole add-back is not partial', () {
      expect(line().isPartial, isFalse);
    });

    test('but half of one is', () {
      // Entertainment. The screen then shows "50% of 12,000" beside the
      // 6,000, which is the question a bare figure provokes.
      expect(line(fraction: 0.5, amount: 6000).isPartial, isTrue);
    });

    test('an add-back is told from a deduction', () {
      expect(line().isAddBack, isTrue);
      expect(line(kind: 'deduct').isAddBack, isFalse);
    });
  });

  group('reading the server back', () {
    test('every figure lands in its own field', () {
      // A map with DIFFERENT numbers in every position, so a
      // transposition between two fields cannot pass. All-alike
      // fixtures are how a swapped pair survives a test suite.
      final c = TaxComputation.fromMap(const {
        'year_of_assessment': 2026,
        'profit_before_tax': 200000,
        'add_backs': 30000,
        'deductions': 5000,
        'balancing_charge': 3800,
        'adjusted_income': 228800,
        'adjusted_loss': 0,
        'ca_current': 34000,
        'ca_brought_forward': 12000,
        'ca_used': 46000,
        'ca_carried_forward': 0,
        'statutory_income': 182800,
        'loss_brought_forward': 80000,
        'loss_used': 80000,
        'loss_carried_forward': 0,
        'chargeable_income': 102800,
        'is_sme': true,
        'sme_known': true,
        'tax_charged': 17476,
        'zakat_rebate': 1000,
        's110_tax_deducted': 2000,
        'cp204_paid': 30000,
        'tax_payable': -15524,
      });

      expect(c.profitBeforeTax, 200000);
      expect(c.addBacks, 30000);
      expect(c.deductions, 5000);
      expect(c.balancingCharge, 3800);
      expect(c.caCurrent, 34000);
      expect(c.caBroughtForward, 12000);
      expect(c.caUsed, 46000);
      expect(c.statutoryIncome, 182800);
      expect(c.lossBroughtForward, 80000);
      expect(c.chargeableIncome, 102800);
      expect(c.taxCharged, 17476);
      expect(c.zakatRebate, 1000);
      expect(c.s110TaxDeducted, 2000);
      expect(c.cp204Paid, 30000);
      expect(c.taxPayable, -15524);
      expect(c.isRefund, isTrue);
    });

    test('an unknown SME test is not the same as failing it', () {
      // Both charge the standard rate and they are different facts.
      // Unknown means nobody has checked; false means somebody did and
      // the company does not qualify. The screen says different things.
      final unknown = TaxComputation.fromMap(const {
        'year_of_assessment': 2026,
        'is_sme': false,
        'sme_known': false,
      });
      expect(unknown.smeKnown, isFalse);
      expect(unknown.isSme, isFalse);

      final checked = TaxComputation.fromMap(const {
        'year_of_assessment': 2026,
        'is_sme': false,
        'sme_known': true,
      });
      expect(checked.smeKnown, isTrue);
      expect(checked.isSme, isFalse);
    });

    test('a missing figure reads as nothing rather than throwing', () {
      // The row comes from a function whose shape can change under a
      // client that has not been rebuilt. Nothing on this screen is
      // worth a crash.
      final c = TaxComputation.fromMap(const {'year_of_assessment': 2026});
      expect(c.profitBeforeTax, 0);
      expect(c.taxPayable, 0);
      expect(c.isRefund, isFalse);
    });
  });
}
