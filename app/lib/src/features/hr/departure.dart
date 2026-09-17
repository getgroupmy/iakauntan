/// Taking somebody off the payroll, and what the screen has to know
/// before it lets somebody try.
///
/// The reason this is its own file is `0371`: the editor has offered
/// Resigned, Terminated and Retired since it was written, and
/// `calculate_payroll_run` has never read `employment_status`. It picks
/// who to pay by `last_working_date`. So a leaver marked in the dropdown
/// kept drawing a full salary, kept having EPF and PCB remitted, and
/// kept being paid by the bank file — while every screen said they had
/// gone.
///
/// The refusals below are the database's, restated so the form can grey
/// out the button rather than let somebody press it and read an error.
/// They are not the enforcement: `record_departure` and the trigger on
/// `employees` are, and a rule enforced only here is not enforced.
library;

/// The three ways an employment ends, in the words a form should use.
///
/// `notice` is not here on purpose. Serving notice is "has resigned, and
/// the last working day has not arrived", which the database derives —
/// offering it as a fourth choice made it a thing somebody typed rather
/// than a thing that was true.
const departureKinds = <String, String>{
  'resigned': 'Resigned',
  'terminated': 'Terminated',
  'retired': 'Retired',
};

/// Whether a resignation date belongs on the form at all.
///
/// The day somebody gave notice is not the day they leave, and only a
/// resignation has one. A termination and a retirement do not — asking
/// for one would invite a date that means nothing, and `0371` writes
/// null for both regardless.
bool takesResignationDate(String kind) => kind == 'resigned';

/// Why this departure cannot be recorded, or null when it can.
///
/// Worded for the person filling the form. The database says the same
/// things and says them last.
String? departureBlockedBecause({
  required String kind,
  required DateTime? lastWorkingDay,
  required DateTime hireDate,
  DateTime? resignationDate,
}) {
  if (!departureKinds.containsKey(kind)) {
    return 'Choose whether they resigned, were terminated, or retired.';
  }
  if (lastWorkingDay == null) {
    return 'A last working day is what takes somebody off the payroll. '
        'Without it the next run still pays them.';
  }
  if (_dayOf(lastWorkingDay).isBefore(_dayOf(hireDate))) {
    return 'A last working day cannot come before the day they joined.';
  }
  if (resignationDate != null &&
      _dayOf(resignationDate).isAfter(_dayOf(lastWorkingDay))) {
    return 'They cannot have given notice after they had already left.';
  }
  return null;
}

/// What the record will say once this is saved.
///
/// Shown on the form because the status is derived rather than chosen,
/// and a derived value nobody sees coming reads as the software having
/// ignored what was typed.
String statusAfterDeparture(String kind, DateTime lastWorkingDay,
    {DateTime? today}) {
  final now = _dayOf(today ?? DateTime.now());
  return _dayOf(lastWorkingDay).isAfter(now) ? 'notice' : kind;
}

/// The sentence under the date field.
String departureEffect(String kind, DateTime? lastWorkingDay,
    {DateTime? today}) {
  if (lastWorkingDay == null) {
    return 'The payroll run goes by this date, not by the status.';
  }
  final after = statusAfterDeparture(kind, lastWorkingDay, today: today);
  if (after == 'notice') {
    return 'They are serving notice until then, and are paid for the days '
        'they work up to it.';
  }
  return 'They are paid up to that day and are not on any run after it.';
}

DateTime _dayOf(DateTime d) => DateTime(d.year, d.month, d.day);
