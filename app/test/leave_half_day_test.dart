import 'package:flutter_test/flutter_test.dart';
import 'package:iakauntan/src/data/models.dart';
import 'package:iakauntan/src/features/hr/leave_screen.dart';

/// The half day `0027` modelled, `0365` wrote a rule about, and nothing
/// could ask for until `0397`.
///
/// The form's job here is not to enforce anything — `app.check_leave_days`
/// and `app.enforce_half_day_rule` do that, and they have to, because
/// this runs on a device somebody else owns. Its job is to not offer
/// what will be refused.
void main() {
  LeaveType type({bool allowHalfDay = true}) => LeaveType(
        id: 't1',
        code: 'AL',
        name: 'Annual leave',
        allowHalfDay: allowHalfDay,
      );

  final monday = DateTime(2026, 9, 7);
  final tuesday = DateTime(2026, 9, 8);

  group('reading the leave type', () {
    test('a type that allows half days says so', () {
      final t = LeaveType.fromJson(const {
        'id': 't1',
        'code': 'AL',
        'name': 'Annual leave',
        'allow_half_day': true,
      });
      expect(t.allowHalfDay, isTrue);
    });

    test('one that forbids them says that', () {
      final t = LeaveType.fromJson(const {
        'id': 't1',
        'code': 'UNPAID',
        'name': 'Unpaid',
        'allow_half_day': false,
      });
      expect(t.allowHalfDay, isFalse);
    });

    test('absent means allowed, matching the column default', () {
      // `0027` gave the column `not null default true`. A select that
      // does not ask for it must not turn every leave type into a
      // whole-day one.
      final t = LeaveType.fromJson(const {
        'id': 't1',
        'code': 'AL',
        'name': 'Annual leave',
      });
      expect(t.allowHalfDay, isTrue);
    });
  });

  group('whether a half day may be asked for', () {
    test('one date, on a type that allows it', () {
      expect(
        canTakeHalfDay(type: type(), start: monday, end: monday),
        isTrue,
      );
    });

    test('not across two dates — a half day is on one', () {
      expect(
        canTakeHalfDay(type: type(), start: monday, end: tuesday),
        isFalse,
      );
    });

    test('not on a type that is taken in whole days', () {
      expect(
        canTakeHalfDay(
          type: type(allowHalfDay: false),
          start: monday,
          end: monday,
        ),
        isFalse,
      );
    });

    test('not before a type is chosen', () {
      expect(
        canTakeHalfDay(type: null, start: monday, end: monday),
        isFalse,
      );
    });

    test('the same day at different times of day is still one date', () {
      // The dates come from a picker and carry whatever time was on
      // them. Comparing the instants rather than the days would make
      // the switch flicker on a value the person did not set.
      expect(
        canTakeHalfDay(
          type: type(),
          start: DateTime(2026, 9, 7, 9, 30),
          end: DateTime(2026, 9, 7, 17, 45),
        ),
        isTrue,
      );
    });
  });

  group('how many days it is for', () {
    test('a half day is half a day', () {
      expect(
        leaveDaysFor(start: monday, end: monday, halfDay: true),
        0.5,
      );
    });

    test('one date is one day', () {
      expect(
        leaveDaysFor(start: monday, end: monday, halfDay: false),
        1,
      );
    });

    test('the span is inclusive of both ends', () {
      expect(
        leaveDaysFor(
          start: monday,
          end: DateTime(2026, 9, 11),
          halfDay: false,
        ),
        5,
      );
    });

    test('never more than the span, which is what the database checks',
        () {
      // `0397` refuses total_days > (end - start + 1). The form cannot
      // produce one, and that is the point of computing it here rather
      // than letting it be typed.
      for (var span = 0; span < 30; span++) {
        final end = monday.add(Duration(days: span));
        final days = leaveDaysFor(start: monday, end: end, halfDay: false);
        expect(days, lessThanOrEqualTo(span + 1));
        expect(days, greaterThanOrEqualTo(0.5));
      }
    });
  });
}
