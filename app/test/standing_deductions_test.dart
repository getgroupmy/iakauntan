import 'package:flutter_test/flutter_test.dart';
import 'package:iakauntan/src/features/hr/standing_deductions.dart';

/// The four figures the payroll engine reads and nothing could set.
///
/// Two of them are statutory: CP38 is an LHDN direction that is remitted
/// with the month's PCB, and zakat is a rebate against PCB rather than
/// another deduction. Getting either wrong is quiet — the payslip
/// balances either way, and the difference is a return filed short or an
/// employee over-taxed for a year.
void main() {
  group('a standing amount', () {
    test('may be left blank, because most employees have none', () {
      // The columns default to zero. Treating blank as an error would
      // make every employee without a CP38 direction unsaveable.
      expect(standingAmountProblem(''), isNull);
      expect(standingAmountProblem('   '), isNull);
    });

    test('and may be zero, said explicitly', () {
      expect(standingAmountProblem('0'), isNull);
    });

    test('but not a negative one', () {
      // A statutory deduction that pays money to somebody is not a
      // thing, and the engine would happily post it.
      expect(standingAmountProblem('-1'), isNotNull);
      expect(standingAmountProblem('-0.01'), isNotNull);
    });

    test('nor something that is not a number', () {
      expect(standingAmountProblem('RM50'), 'Enter a number');
      expect(standingAmountProblem('fifty'), 'Enter a number');
    });

    test('and an ordinary figure passes', () {
      expect(standingAmountProblem('150.50'), isNull);
    });
  });

  group('a voluntary EPF rate', () {
    test('carries every rule an amount does', () {
      expect(voluntaryRateProblem(''), isNull);
      expect(voluntaryRateProblem('-1'), isNotNull);
      expect(voluntaryRateProblem('nope'), 'Enter a number');
    });

    test('and refuses a fraction, which is the silent mistake', () {
      // The engine divides by 100. Somebody reading "rate" as a fraction
      // enters 0.02 for two per cent and contributes a two-hundredth of
      // what they meant — not refused by anything, plausible on every
      // payslip, and discovered at retirement.
      final why = voluntaryRateProblem('0.02');
      expect(why, isNotNull);
      expect(why, contains('two per cent'));
    });

    test('and an amount typed into the rate box', () {
      // The same mistake the other way: 500 is somebody entering
      // ringgit where a percentage goes.
      expect(voluntaryRateProblem('500'), isNotNull);
    });

    test('accepting the rates employers actually use', () {
      // A whole percentage, a half point, the boundary, and zero.
      for (final r in const ['2', '4.5', '1', '100', '0']) {
        expect(voluntaryRateProblem(r), isNull, reason: r);
      }
    });
  });

  group('what reaches the row', () {
    test('blank becomes zero, not null', () {
      // All four columns are `not null`. A null is refused with an error
      // about a constraint rather than about the empty box that caused
      // it, which is the wrong sentence to put in front of somebody.
      final v = standingDeductionValues(
        cp38: '',
        zakat: '  ',
        voluntaryEmployee: '',
        voluntaryEmployer: '',
      );
      expect(v.values.every((x) => x == 0), isTrue, reason: '$v');
    });

    test('and the figures are keyed the way the columns are named', () {
      // A key that does not match a column is not an error either: the
      // row saves and the field is silently dropped.
      final v = standingDeductionValues(
        cp38: '150',
        zakat: '80',
        voluntaryEmployee: '2',
        voluntaryEmployer: '4',
      );
      expect(v['cp38_monthly'], 150);
      expect(v['zakat_monthly'], 80);
      expect(v['epf_voluntary_employee_rate'], 2);
      expect(v['epf_voluntary_employer_rate'], 4);
      expect(v.keys.length, 4);
    });
  });
}
