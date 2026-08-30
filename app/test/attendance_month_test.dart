import 'package:flutter_test/flutter_test.dart';
import 'package:iakauntan/src/data/models.dart';
import 'package:iakauntan/src/features/hr/attendance_month.dart';

AttendanceRecord record({
  DateTime? inAt,
  DateTime? outAt,
  int worked = 480,
  int late = 0,
  int ot = 0,
  String status = 'present',
  String? who,
}) => AttendanceRecord(
  id: 'a1',
  workDate: DateTime(2026, 8, 17),
  status: status,
  employeeName: who,
  clockIn: inAt,
  clockOut: outAt,
  workedMinutes: worked,
  lateMinutes: late,
  otMinutes: ot,
);

void main() {
  group('how a day reads', () {
    test('the two stamps, when both are there', () {
      final s = attendanceLine(record(
        inAt: DateTime(2026, 8, 17, 8, 55),
        outAt: DateTime(2026, 8, 17, 18, 2),
      ));
      expect(s, contains('08:55'));
      expect(s, contains('18:02'));
    });

    test('a day still open says so rather than showing an end', () {
      // Somebody who forgot to clock out and somebody who worked no
      // hours are different days, and only one of them needs chasing.
      final s = attendanceLine(record(inAt: DateTime(2026, 8, 17, 8, 55)));
      expect(s, contains('08:55'));
      expect(s, contains('still open'));
    });

    test('a day nobody clocked into reads as its status', () {
      expect(attendanceLine(record(status: 'leave', worked: 0)), 'Leave');
      expect(attendanceLine(record(status: 'absent', worked: 0)), 'Absent');
    });
  });

  group('hours', () {
    test('are stated the way a payslip states them', () {
      expect(workedLabel(480), '8.00h');
      expect(workedLabel(510), '8.50h');
      expect(workedLabel(0), '0.00h');
    });
  });

  group('what is worth flagging', () {
    test('lateness', () {
      expect(attendanceFlags(record(late: 12)), '12 min late');
    });

    test('overtime, in hours', () {
      expect(attendanceFlags(record(ot: 90)), '1.50h overtime');
    });

    test('both, when there are both', () {
      final s = attendanceFlags(record(late: 12, ot: 90))!;
      expect(s, contains('12 min late'));
      expect(s, contains('1.50h overtime'));
    });

    test('nothing on an ordinary day', () {
      // A column of "0 late" trains people to stop reading it.
      expect(attendanceFlags(record()), isNull);
    });
  });

  group('the month added up', () {
    test('counts the days somebody actually clocked into', () {
      // A day nobody clocked into is a row about an absence, and
      // counting it would flatter the total.
      final t = attendanceTotals([
        record(inAt: DateTime(2026, 8, 17, 9), outAt: DateTime(2026, 8, 17, 18)),
        record(inAt: DateTime(2026, 8, 18, 9), outAt: DateTime(2026, 8, 18, 18)),
        record(status: 'leave', worked: 0),
      ]);
      expect(t.days, 2);
    });

    test('adds the minutes worked, late and over', () {
      final t = attendanceTotals([
        record(inAt: DateTime(2026, 8, 17, 9), worked: 480, late: 12, ot: 30),
        record(inAt: DateTime(2026, 8, 18, 9), worked: 500, late: 0, ot: 60),
      ]);
      expect(t.worked, 980);
      expect(t.late, 12);
      expect(t.overtime, 90);
    });

    test('an empty month is all zeroes rather than nothing', () {
      final t = attendanceTotals(const []);
      expect(t.days, 0);
      expect(t.worked, 0);
      expect(t.late, 0);
      expect(t.overtime, 0);
    });

    test('a day of leave still carries no hours into the total', () {
      final t = attendanceTotals([record(status: 'leave', worked: 0)]);
      expect(t.worked, 0);
      expect(t.days, 0);
    });
  });
}
