/// Turning a candidate into an employee: what the form has to answer
/// for, and what it may not decide on its own.
///
/// The rules live in `0381`'s `hire_applicant`, which is where they are
/// enforced. What is here is the part the form can answer before the
/// round trip, so a refusal that the person can fix from the box in
/// front of them arrives as a sentence rather than a database error.
library;

/// The earliest day a candidate could start, given the notice they owe
/// their current employer.
///
/// Null when they owe none, which is the honest answer for somebody
/// between jobs — not "today", which would read as a rule that had been
/// applied.
DateTime? earliestStartDate({
  required int? noticePeriodDays,
  required DateTime today,
}) {
  if (noticePeriodDays == null || noticePeriodDays <= 0) return null;
  return DateTime(today.year, today.month, today.day + noticePeriodDays);
}

/// Whether a start date needs somebody to say why it is inside the
/// candidate's notice period.
///
/// Notice does get waived and bought out, so this is a question rather
/// than a refusal — a refusal with no way through is how somebody puts
/// the wrong date in to get past the screen.
bool startNeedsExplaining({
  required DateTime? hireDate,
  required int? noticePeriodDays,
  required DateTime today,
}) {
  if (hireDate == null) return false;
  final earliest =
      earliestStartDate(noticePeriodDays: noticePeriodDays, today: today);
  if (earliest == null) return false;
  return DateTime(hireDate.year, hireDate.month, hireDate.day)
      .isBefore(earliest);
}

/// What the form will not send, in the words to show if so.
///
/// Null when it is fine.
String? hireBlockedBecause({
  required String employeeNo,
  required DateTime? hireDate,
  required num? basicSalary,
  required int? noticePeriodDays,
  required String? earlyStartNote,
  required DateTime today,
}) {
  if (employeeNo.trim().isEmpty) return 'Give them an employee number.';
  if (hireDate == null) return 'Say when they start.';
  if (basicSalary == null || basicSalary <= 0) {
    return 'A salary of nothing is not an offer.';
  }
  if (startNeedsExplaining(
        hireDate: hireDate,
        noticePeriodDays: noticePeriodDays,
        today: today,
      ) &&
      (earlyStartNote == null || earlyStartNote.trim().isEmpty)) {
    return 'That is inside their $noticePeriodDays days\' notice. Say why '
        'the date stands — waived, bought out — and it will.';
  }
  return null;
}

/// How many of a requisition's places are still open.
///
/// Negative is not possible through `hire_applicant`, which refuses the
/// hire that would cause it, but a headcount lowered afterwards can
/// leave more people hired than places. Clamped, because a screen
/// saying "-1 remaining" is a screen reporting arithmetic rather than a
/// fact about the company.
int placesRemaining({required int headcount, required int hired}) {
  final left = headcount - hired;
  return left < 0 ? 0 : left;
}
