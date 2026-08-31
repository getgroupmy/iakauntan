/// The four standing figures on an employee that the payroll engine
/// reads and nothing could ever set.
///
/// All four are columns on `employees` with `not null default 0`, all
/// four are read by `calculate_payroll_run`, and none of them appeared
/// on any screen. So the engine was right and the data could not
/// arrive:
///
///   * **cp38_monthly** — what LHDN has directed be deducted on top of
///     the month's PCB. `post_payroll_run` remits `pcb + cp38`
///     together, so a direction that arrives in the post has nowhere to
///     go and the arrears are simply not deducted.
///   * **zakat_monthly** — a rebate against PCB rather than another
///     deduction; the engine passes it into the PCB calculation. Left
///     at zero, an employee paying zakat over-pays PCB every month.
///   * **epf_voluntary_employee_rate / employer_rate** — contributions
///     above the statutory rate, which a great many Malaysian employers
///     make.
///
/// The validation below is here rather than inline because one of these
/// is a unit trap rather than a typo, and a unit trap is silent.
library;

/// What is wrong with a standing amount, or null when nothing is.
///
/// Blank is not an error: the columns default to zero and an employee
/// with no CP38 direction has no figure to enter. What is refused is a
/// negative one — a deduction that pays money *to* somebody through the
/// statutory line is not a thing.
String? standingAmountProblem(String raw) {
  final text = raw.trim();
  if (text.isEmpty) return null;
  final value = double.tryParse(text);
  if (value == null) return 'Enter a number';
  if (value < 0) return 'Cannot be less than nothing';
  return null;
}

/// What is wrong with a voluntary EPF rate, or null when nothing is.
///
/// The extra rule is the one worth having. The column is a percentage
/// and the engine divides by 100, so an employer contributing two
/// points above the statutory rate enters `2`. Somebody who reads
/// "rate" as a fraction enters `0.02` and contributes a two-hundredth
/// of what they meant — which is not refused by anything, produces a
/// plausible small number on every payslip, and is discovered by an
/// employee at retirement.
///
/// The upper bound catches the same mistake the other way: a rate above
/// 100 is somebody entering an amount in the rate box.
String? voluntaryRateProblem(String raw) {
  final basic = standingAmountProblem(raw);
  if (basic != null) return basic;
  final text = raw.trim();
  if (text.isEmpty) return null;
  final value = double.parse(text);
  if (value > 100) return 'A rate, not an amount — 2 means two per cent';
  if (value > 0 && value < 1) {
    return 'A percentage, not a fraction — 2 means two per cent';
  }
  return null;
}

/// The four values as the row wants them.
///
/// Blank becomes zero rather than null, because all four columns are
/// `not null` and a null would be refused by the database with an error
/// about a constraint rather than about the empty box that caused it.
Map<String, Object?> standingDeductionValues({
  required String cp38,
  required String zakat,
  required String voluntaryEmployee,
  required String voluntaryEmployer,
}) => {
  'cp38_monthly': _zeroOr(cp38),
  'zakat_monthly': _zeroOr(zakat),
  'epf_voluntary_employee_rate': _zeroOr(voluntaryEmployee),
  'epf_voluntary_employer_rate': _zeroOr(voluntaryEmployer),
};

double _zeroOr(String raw) => double.tryParse(raw.trim()) ?? 0;
