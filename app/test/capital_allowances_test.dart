import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/data/models.dart';

/// The Dart side of the Schedule 3 working.
///
/// The arithmetic itself is in SQL and asserted there —
/// `supabase/tests/capital_allowances.sql` is where a rate or a cap
/// moving fails. What is asserted HERE is everything the screen decides
/// once the figures have arrived, and there are three such decisions,
/// each of which would be wrong silently:
///
///   1. **The cast.** An accountant totals a schedule before believing
///      a line of it. The four totals go to four different places on a
///      return — allowances and a balancing allowance are deductions, a
///      balancing charge is taxable, the residual carries forward — so
///      summing them into one figure would be arithmetic that is right
///      and an answer that is wrong.
///   2. **Spotting a restricted asset**, which is the difference
///      between "your car cost RM300,000" and "you are allowed
///      RM100,000 of it".
///   3. **Spotting a misfiled one.** An asset in a small value class
///      that is not a small value asset gets nothing at all — the safe
///      direction, and invisible unless the screen says so.
void main() {
  CapitalAllowanceLine line({
    String no = 'A-1',
    String classCode = 'plant',
    double cost = 10000,
    double? qualifying,
    double initial = 2000,
    double annual = 1400,
    double prior = 0,
    double ba = 0,
    double bc = 0,
    double? claimed,
    double residual = 6600,
  }) => CapitalAllowanceLine(
    assetId: no,
    assetNo: no,
    name: 'Thing',
    classCode: classCode,
    classLabel: 'Plant and machinery',
    acquired: DateTime(2024, 1, 1),
    cost: cost,
    qualifying: qualifying ?? cost,
    initial: initial,
    annual: annual,
    priorClaimed: prior,
    balancingAllowance: ba,
    balancingCharge: bc,
    claimed: claimed ?? initial + annual,
    residual: residual,
  );

  group('the cast', () {
    test('adds each column down its own length', () {
      final totals = capitalAllowanceTotals([
        line(no: 'A-1'),
        line(no: 'A-2', initial: 1000, annual: 700, residual: 3300),
      ]);
      expect(totals.claimed, 3400 + 1700);
      expect(totals.residual, 6600 + 3300);
      expect(totals.qualifying, 20000);
    });

    test('keeps the balancing allowance and the charge apart', () {
      // They must never be netted. One is deducted from adjusted income
      // and the other is added back as taxable, so a single "balancing"
      // total of 300 would be two wrong figures that happen to add up.
      final totals = capitalAllowanceTotals([
        line(no: 'A-1', ba: 2200, annual: 0, claimed: 2000, residual: 0),
        line(no: 'A-2', bc: 1900, annual: 0, claimed: 2000, residual: 0),
      ]);
      expect(totals.balancingAllowance, 2200);
      expect(totals.balancingCharge, 1900);
    });

    test('and the claimed total excludes both of them', () {
      // `claimed` is the initial and annual allowances, which is what a
      // computation subtracts. The balancing figures go elsewhere on
      // the return, and folding them in here would double-count one and
      // sign-flip the other.
      final totals = capitalAllowanceTotals([
        line(no: 'A-1', initial: 2000, annual: 1400, ba: 5000, bc: 0),
      ]);
      expect(totals.claimed, 3400);
    });

    test('an empty schedule totals nothing rather than throwing', () {
      final totals = capitalAllowanceTotals(const []);
      expect(totals.claimed, 0);
      expect(totals.residual, 0);
    });
  });

  group('a restricted asset', () {
    test('is one whose qualifying expenditure is below its cost', () {
      expect(line(cost: 300000, qualifying: 100000).isRestricted, isTrue);
    });

    test('and one under the cap is not', () {
      expect(line(cost: 80000, qualifying: 80000).isRestricted, isFalse);
    });

    test('nor is an ordinary asset with no cap at all', () {
      expect(line().isRestricted, isFalse);
    });
  });

  group('an asset that was filed in the wrong class', () {
    test('got nothing, and its residual is the whole qualifying sum', () {
      // `0664` gives nothing to an asset in a small value class that is
      // not under the threshold — RM2,000 exactly is not under RM2,000.
      // Writing it off in full because somebody picked the wrong class
      // is the one direction this must never fail in, so the schedule
      // says nothing and the screen says why.
      final misfiled = line(
        classCode: 'small_value',
        cost: 2000,
        initial: 0,
        annual: 0,
        claimed: 0,
        residual: 2000,
      );
      expect(misfiled.looksMisclassified, isTrue);
    });

    test('but an asset simply written down to nothing is not that', () {
      // Nothing claimed this year and nothing left: an ordinary asset
      // at the end of its life. Calling it misfiled would put a red
      // notice on every register with an old asset in it.
      final spent = line(
        initial: 0,
        annual: 0,
        prior: 10000,
        claimed: 0,
        residual: 0,
      );
      expect(spent.looksMisclassified, isFalse);
    });

    test('nor is one part way through its life', () {
      expect(line(prior: 3400, residual: 5200).looksMisclassified, isFalse);
    });

    test('nor an asset that cost nothing', () {
      // `fixed_assets` allows a cost of zero -- the check is `>= 0` --
      // and such an asset satisfies every other condition trivially:
      // nothing claimed, nothing prior, and a residual equal to its
      // qualifying sum because both are zero. A red notice on it would
      // be a notice about nothing.
      final free = line(
        cost: 0,
        qualifying: 0,
        initial: 0,
        annual: 0,
        claimed: 0,
        residual: 0,
      );
      expect(free.looksMisclassified, isFalse);
    });

    test('nor one disposed of this year', () {
      final sold = line(
        initial: 0,
        annual: 0,
        prior: 4800,
        ba: 2200,
        claimed: 0,
        residual: 0,
      );
      expect(sold.looksMisclassified, isFalse);
    });
  });

  group('how a class reads when somebody is choosing one', () {
    test('as the two rates they are comparing', () {
      final c = CapitalAllowanceClass(
        code: 'plant',
        label: 'Plant and machinery',
        initialRate: 0.20,
        annualRate: 0.14,
      );
      expect(c.rates, '20% then 14%');
    });

    test('including one with no annual allowance at all', () {
      final c = CapitalAllowanceClass(
        code: 'small_value',
        label: 'Small value asset',
        initialRate: 1,
        annualRate: 0,
      );
      expect(c.rates, '100% then 0%');
    });

    test('and nothing is seeded claiming to be checked against the Act', () {
      // The default matters: `0025` uses the same flag on the payroll
      // schedules, and a class that defaulted to verified would be a
      // figure nobody was told to check.
      final c = CapitalAllowanceClass(
        code: 'plant',
        label: 'Plant',
        initialRate: 0.2,
        annualRate: 0.14,
      );
      expect(c.isVerified, isFalse);
    });
  });
}
