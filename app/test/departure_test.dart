import 'package:flutter_test/flutter_test.dart';
import 'package:iakauntan/src/features/hr/departure.dart';

/// The form in front of `record_departure`.
///
/// Everything here is a restatement of a rule the database holds, and it
/// exists so the button is grey rather than so the rule is kept. The one
/// thing that is genuinely this file's own is the derived status: the
/// person filling the form chose "Resigned" and the record will say
/// "Serving notice", and a derived value nobody sees coming reads as the
/// software having ignored them.
void main() {
  final hired = DateTime(2020, 1, 1);

  group('what the form will not send', () {
    test('a departure with no last working day', () {
      // The whole defect in one assertion. Before 0371 this was the
      // ordinary case, and the next payroll run paid them in full.
      final why = departureBlockedBecause(
        kind: 'resigned',
        lastWorkingDay: null,
        hireDate: hired,
      );
      expect(why, isNotNull);
      expect(why, contains('still pays them'));
    });

    test('leaving before joining', () {
      expect(
        departureBlockedBecause(
          kind: 'resigned',
          lastWorkingDay: DateTime(2019, 6, 1),
          hireDate: hired,
        ),
        contains('before the day they joined'),
      );
    });

    test('and notice given after they had gone', () {
      // Not a rule the database keeps — it stores both dates as given.
      // Kept here because the pair is nonsense on its face and the form
      // is where somebody can still fix it.
      expect(
        departureBlockedBecause(
          kind: 'resigned',
          lastWorkingDay: DateTime(2026, 4, 15),
          hireDate: hired,
          resignationDate: DateTime(2026, 5, 1),
        ),
        contains('after they had already left'),
      );
    });

    test('a kind that is not a departure', () {
      expect(
        departureBlockedBecause(
          kind: 'suspended',
          lastWorkingDay: DateTime(2026, 4, 15),
          hireDate: hired,
        ),
        isNotNull,
      );
    });

    test('but an ordinary one goes through', () {
      expect(
        departureBlockedBecause(
          kind: 'terminated',
          lastWorkingDay: DateTime(2026, 4, 15),
          hireDate: hired,
        ),
        isNull,
      );
      // The same day they joined: one day of employment is a day.
      expect(
        departureBlockedBecause(
          kind: 'resigned',
          lastWorkingDay: hired,
          hireDate: hired,
        ),
        isNull,
      );
    });
  });

  group('the status that comes out of it', () {
    test('is the kind chosen, once the day has passed', () {
      expect(
        statusAfterDeparture('resigned', DateTime(2026, 4, 15),
            today: DateTime(2026, 5, 1)),
        'resigned',
      );
      expect(
        statusAfterDeparture('retired', DateTime(2026, 4, 15),
            today: DateTime(2026, 4, 15)),
        'retired',
        reason: 'the last working day is a day they worked',
      );
    });

    test('and serving notice while it is still to come', () {
      expect(
        statusAfterDeparture('resigned', DateTime(2026, 6, 30),
            today: DateTime(2026, 4, 15)),
        'notice',
      );
      // Terminated with a future date is still notice: the employment
      // has not ended yet, whoever ended it.
      expect(
        statusAfterDeparture('terminated', DateTime(2026, 6, 30),
            today: DateTime(2026, 4, 15)),
        'notice',
      );
    });

    test('measured by the day and not the hour', () {
      // A departure recorded at nine in the morning for that same day
      // must not read as notice until midnight.
      expect(
        statusAfterDeparture('resigned', DateTime(2026, 4, 15),
            today: DateTime(2026, 4, 15, 9)),
        'resigned',
      );
    });
  });

  group('what the form says under the date', () {
    test('names the consequence rather than the field', () {
      expect(
        departureEffect('resigned', DateTime(2026, 4, 15),
            today: DateTime(2026, 5, 1)),
        contains('not on any run after it'),
      );
      expect(
        departureEffect('resigned', DateTime(2026, 6, 30),
            today: DateTime(2026, 4, 15)),
        contains('serving notice'),
      );
    });

    test('and with no date, says what the date is for', () {
      expect(departureEffect('resigned', null), contains('goes by this date'));
    });
  });

  group('which dates a kind carries', () {
    test('only a resignation has a day notice was given', () {
      expect(takesResignationDate('resigned'), isTrue);
      expect(takesResignationDate('terminated'), isFalse);
      expect(takesResignationDate('retired'), isFalse);
    });
  });

  test('the three kinds, and not the derived one', () {
    // `notice` is what the database works out; offering it here would
    // make it a thing somebody types rather than a thing that is true.
    expect(departureKinds.keys.toSet(), {
      'resigned',
      'terminated',
      'retired',
    });
  });
}
