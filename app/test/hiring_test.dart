import 'package:flutter_test/flutter_test.dart';
import 'package:iakauntan/src/features/hr/hiring.dart';

/// The form in front of `hire_applicant`.
///
/// The rules are the database's — `0381` — and these assertions are
/// about the form agreeing with them, so a refusal the person can fix
/// from the box in front of them arrives as a sentence.
void main() {
  final today = DateTime(2026, 7, 10);

  group('the notice they owe somebody else', () {
    test('is counted forward from today', () {
      expect(
        earliestStartDate(noticePeriodDays: 30, today: today),
        DateTime(2026, 8, 9),
      );
    });

    test('and somebody between jobs owes none', () {
      // Null rather than today: "today" would read as a rule that had
      // been applied and come out to nothing.
      expect(earliestStartDate(noticePeriodDays: null, today: today), isNull);
      expect(earliestStartDate(noticePeriodDays: 0, today: today), isNull);
    });

    test('a date inside it has to be explained', () {
      expect(
        startNeedsExplaining(
          hireDate: DateTime(2026, 8, 1),
          noticePeriodDays: 30,
          today: today,
        ),
        isTrue,
      );
    });

    test('the first day past it does not', () {
      expect(
        startNeedsExplaining(
          hireDate: DateTime(2026, 8, 9),
          noticePeriodDays: 30,
          today: today,
        ),
        isFalse,
      );
    });

    test('nor does any date when no notice is owed', () {
      expect(
        startNeedsExplaining(
          hireDate: DateTime(2026, 7, 11),
          noticePeriodDays: null,
          today: today,
        ),
        isFalse,
      );
    });

    test('and a date not yet chosen is not a problem yet', () {
      expect(
        startNeedsExplaining(
          hireDate: null,
          noticePeriodDays: 30,
          today: today,
        ),
        isFalse,
      );
    });
  });

  group('what the form will not send', () {
    String? blocked({
      String employeeNo = 'E-1',
      DateTime? hireDate,
      num? salary = 4500,
      int? notice,
      String? note,
    }) =>
        hireBlockedBecause(
          employeeNo: employeeNo,
          hireDate: hireDate ?? DateTime(2026, 9, 1),
          basicSalary: salary,
          noticePeriodDays: notice,
          earlyStartNote: note,
          today: today,
        );

    test('a hire with no employee number', () {
      expect(blocked(employeeNo: '  '), contains('employee number'));
    });

    test('a hire with no start date', () {
      expect(
        hireBlockedBecause(
          employeeNo: 'E-1',
          hireDate: null,
          basicSalary: 4500,
          noticePeriodDays: null,
          earlyStartNote: null,
          today: today,
        ),
        contains('when they start'),
      );
    });

    test('an offer of nothing', () {
      expect(blocked(salary: 0), contains('not an offer'));
      expect(blocked(salary: null), contains('not an offer'));
    });

    test('a start inside the notice, unexplained', () {
      final why = blocked(hireDate: DateTime(2026, 8, 1), notice: 30);
      expect(why, contains("30 days' notice"));
      expect(why, contains('bought out'));
    });

    test('and the same start once it is explained', () {
      expect(
        blocked(
          hireDate: DateTime(2026, 8, 1),
          notice: 30,
          note: 'Bought out by us.',
        ),
        isNull,
      );
    });

    test('whitespace is not an explanation', () {
      expect(
        blocked(hireDate: DateTime(2026, 8, 1), notice: 30, note: '   '),
        isNotNull,
      );
    });

    test('and an ordinary offer goes through', () {
      expect(blocked(), isNull);
    });
  });

  group('places left on a requisition', () {
    test('the arithmetic', () {
      expect(placesRemaining(headcount: 3, hired: 1), 2);
      expect(placesRemaining(headcount: 1, hired: 1), 0);
    });

    test('and a headcount lowered under the hires reads as none', () {
      // `hire_applicant` refuses the hire that would overfill, but a
      // headcount edited downwards afterwards can leave more people
      // than places. "-1 remaining" reports arithmetic rather than a
      // fact about the company.
      expect(placesRemaining(headcount: 1, hired: 3), 0);
    });
  });
}
