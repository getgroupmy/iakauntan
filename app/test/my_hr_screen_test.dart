import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/core/providers.dart';
import 'package:iakauntan/src/core/theme.dart';
import 'package:iakauntan/src/data/models.dart';
import 'package:iakauntan/src/features/hr/my_hr_screen.dart';

/// What an employee sees about themselves.
///
/// Two things live only in this widget.
///
/// THE THREE CLOCK STATES. Not clocked in, clocked in, done for today --
/// derived from two nullable timestamps, so there are four combinations
/// and only three states. The one that matters is DONE: the button
/// disappears entirely, because a second clock-in after clocking out
/// starts a day that already ended, and payroll reads these minutes.
///
/// AND WHAT IS LEFT OF THE LEAVE. `available` is entitlement plus
/// carry-forward plus adjustment, less what is taken AND what is
/// pending. Leaving pending out is the mistake worth a test: it shows
/// somebody days they have already asked for, they book against them,
/// and HR refuses a request the screen said was affordable.
void main() {
  Employee employee({
    String id = 'e1',
    String name = 'Nurul Huda binti Rahman',
    String no = 'E-0042',
  }) => Employee(id: id, employeeNo: no, fullName: name);

  AttendanceRecord record({
    DateTime? clockIn,
    DateTime? clockOut,
    int workedMinutes = 0,
    int lateMinutes = 0,
  }) => AttendanceRecord(
    id: 'a1',
    workDate: DateTime(2026, 9, 16),
    status: 'present',
    clockIn: clockIn,
    clockOut: clockOut,
    workedMinutes: workedMinutes,
    lateMinutes: lateMinutes,
  );

  LeaveBalance balance({
    String name = 'Annual Leave',
    double entitled = 16,
    double carriedForward = 2,
    double adjustment = 0,
    double taken = 4,
    double pending = 1,
  }) => LeaveBalance(
    leaveTypeId: 'lt-$name',
    leaveTypeName: name,
    entitled: entitled,
    carriedForward: carriedForward,
    adjustment: adjustment,
    taken: taken,
    pending: pending,
  );

  // A flag rather than a nullable `me`: `me ?? employee()` would turn
  // the "no employee record" case back into an ordinary employee, and
  // the test asserting the empty state would fail against a screen that
  // was working perfectly.
  Widget wrap({
    bool noEmployee = false,
    AttendanceRecord? today,
    List<LeaveBalance> leave = const [],
  }) => ProviderScope(
    overrides: [
      myEmployeeProvider.overrideWith((ref) async => noEmployee ? null : employee()),
      myAttendanceTodayProvider.overrideWith((ref) async => today),
      myLeaveBalancesProvider.overrideWith((ref) async => leave),
      myPayslipsProvider.overrideWith((ref) async => const []),
    ],
    child: MaterialApp(
      theme: AppTheme.light(),
      home: const MyHrScreen(),
    ),
  );

  Future<void> show(
    WidgetTester tester, {
    bool noEmployee = false,
    AttendanceRecord? today,
    List<LeaveBalance> leave = const [],
  }) async {
    await tester.pumpWidget(
        wrap(noEmployee: noEmployee, today: today, leave: leave));
    await tester.pumpAndSettle();
  }

  group('the three clock states', () {
    testWidgets('nothing yet today offers a clock in', (tester) async {
      await show(tester, today: null);

      expect(find.text('Not clocked in'), findsOneWidget);
      expect(find.text('Clock in'), findsOneWidget);
      expect(find.text('Clock out'), findsNothing);
    });

    testWidgets('clocked in and not out offers a clock out', (tester) async {
      await show(tester, today: record(
        clockIn: DateTime(2026, 9, 16, 8, 55),
        clockOut: null,
      ));

      expect(find.text('Clocked in'), findsOneWidget);
      expect(find.text('Clock out'), findsOneWidget);
      expect(find.text('Clock in'), findsNothing);
    });

    testWidgets('and a day already finished offers neither', (tester) async {
      // The one that matters. A second clock-in after clocking out
      // starts a day that has already ended, and payroll reads these
      // minutes.
      await show(tester, today: record(
        clockIn: DateTime(2026, 9, 16, 8, 55),
        clockOut: DateTime(2026, 9, 16, 18, 2),
        workedMinutes: 547,
      ));

      expect(find.text('Done for today'), findsOneWidget);
      expect(find.text('Clock in'), findsNothing);
      expect(find.text('Clock out'), findsNothing);
    });

    // `clockedIn` is `clockIn != null && clockOut == null`, and that
    // second half is redundant: every one of its five uses sits inside
    // `done ? ... : clockedIn` or `if (!done)`, so it is never read when
    // there IS a clock out. Dropping it survives the whole file and no
    // test can catch it. Said here rather than left as a gap.
    testWidgets('a clock out with no clock in is still finished',
        (tester) async {
      // The fourth combination of two nullables, which has only three
      // states to land in. `done` is tested first, so this reads as
      // finished rather than as never started -- and NOT offering a
      // clock-in is right either way: the day is not in a state this
      // card can fix.
      await show(tester, today: record(
        clockIn: null,
        clockOut: DateTime(2026, 9, 16, 18, 2),
      ));

      expect(find.text('Done for today'), findsOneWidget);
      expect(find.text('Clock in'), findsNothing);
    });
  });

  group('what the day says', () {
    testWidgets('the times, the hours and the lateness', (tester) async {
      await show(tester, today: record(
        clockIn: DateTime(2026, 9, 16, 9, 12),
        clockOut: DateTime(2026, 9, 16, 18, 2),
        workedMinutes: 530,
        lateMinutes: 12,
      ));

      // 530 minutes is 8.8 hours, to one place.
      expect(
        find.textContaining('8.8 h'),
        findsOneWidget,
      );
      expect(find.textContaining('12 min late'), findsOneWidget);
      expect(find.textContaining('In '), findsOneWidget);
      expect(find.textContaining('Out '), findsOneWidget);
    });

    testWidgets('and says nothing about lateness when there is none',
        (tester) async {
      // The control. "0 min late" on every punctual day is how a real
      // one stops being read.
      await show(tester, today: record(
        clockIn: DateTime(2026, 9, 16, 8, 55),
        clockOut: DateTime(2026, 9, 16, 18, 2),
        workedMinutes: 547,
        lateMinutes: 0,
      ));

      expect(find.textContaining('late'), findsNothing);
    });

    testWidgets('a day with no record shows the date instead of a blank',
        (tester) async {
      await show(tester, today: null);

      // Not an empty line under "Not clocked in".
      expect(find.textContaining('In '), findsNothing);
      expect(find.text('Not clocked in'), findsOneWidget);
    });

    testWidgets('the month behind today is reachable', (tester) async {
      // The card had only ever shown the current day, so nobody could
      // check their own attendance before payroll ran on it.
      await show(tester, today: null);

      expect(find.byKey(const ValueKey('my-attendance-month')),
          findsOneWidget);
    });
  });

  group('what is left of the leave', () {
    testWidgets('pending days are already spent', (tester) async {
      // 16 entitled + 2 carried + 0 adjustment - 4 taken - 1 pending =
      // 13. Leave the pending out and the pill says 14: somebody books
      // against a day they have already asked for, and HR refuses a
      // request this screen called affordable.
      await show(tester, leave: [
        balance(entitled: 16, carriedForward: 2, taken: 4, pending: 1),
      ]);

      expect(find.text('13'), findsOneWidget);
      expect(find.textContaining('4 taken'), findsOneWidget);
      expect(find.textContaining('1 pending'), findsOneWidget);
    });

    testWidgets('an adjustment counts too', (tester) async {
      // 10 + 0 + 3 - 0 - 0 = 13. The adjustment column exists for
      // unused days bought back or granted, and dropping it from the
      // sum is invisible on every employee who has none.
      await show(tester, leave: [
        balance(entitled: 10, carriedForward: 0, adjustment: 3,
            taken: 0, pending: 0),
      ]);

      expect(find.text('13'), findsOneWidget);
    });

    testWidgets('and nothing pending is not mentioned', (tester) async {
      await show(tester, leave: [
        balance(entitled: 16, carriedForward: 0, taken: 4, pending: 0),
      ]);

      expect(find.text('12'), findsOneWidget);
      expect(find.textContaining('pending'), findsNothing);
      expect(find.textContaining('4 taken'), findsOneWidget);
    });

    testWidgets('an employee with no entitlement is told so', (tester) async {
      await show(tester, leave: const []);

      expect(find.textContaining('No leave entitlement has been set up yet'),
          findsOneWidget);
    });
  });

  group('somebody with no employee record', () {
    testWidgets('is told what to ask for', (tester) async {
      // A login that is not linked to an employee is an ordinary state
      // on the day somebody joins, and an empty screen reads as broken.
      await show(tester, noEmployee: true);

      expect(find.text('No employee record'), findsOneWidget);
      expect(find.textContaining('Ask HR to connect them'), findsOneWidget);
    });
  });
}
