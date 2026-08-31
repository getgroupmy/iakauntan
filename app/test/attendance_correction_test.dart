import 'package:flutter_test/flutter_test.dart';
import 'package:iakauntan/src/data/models.dart';
import 'package:iakauntan/src/features/hr/attendance_month.dart';

/// Correcting a day, and the one day that cannot be corrected.
///
/// 0360 made `incomplete` reachable and 0363 gave it a way out. What
/// the screen has to decide first is which rows a correction even makes
/// sense for — and the answer is not "the ones HR may touch", it is
/// "the ones with times on them".
void main() {
  AttendanceRecord day(
    String status, {
    DateTime? inAt,
    DateTime? outAt,
    bool adjusted = false,
  }) => AttendanceRecord(
    id: 'r',
    workDate: DateTime(2026, 6, 2),
    status: status,
    clockIn: inAt,
    clockOut: outAt,
    isAdjusted: adjusted,
  );

  final nine = DateTime(2026, 6, 2, 9, 5);
  final six = DateTime(2026, 6, 2, 18, 0);

  group('which days can be corrected', () {
    test('the forgotten punch-out, which is the whole point', () {
      // 0360 marks it `incomplete`; `clock_out` only touches today, so
      // without a correction it stays that way forever.
      expect(correctionBlockedBecause(day('incomplete', inAt: nine)), isNull);
    });

    test('and an ordinary day, because the times can still be wrong', () {
      expect(
        correctionBlockedBecause(day('present', inAt: nine, outAt: six)),
        isNull,
      );
    });

    test('but not an absence, which has no times on it', () {
      // Giving an absence clock times would turn it into a day worked
      // without anybody saying so. That is booking leave or reversing
      // it, and it belongs on a different screen.
      for (final s in const ['absent', 'on_leave', 'rest_day']) {
        expect(correctionBlockedBecause(day(s)), isNotNull, reason: s);
      }
    });

    test('and the refusal says what the day is instead', () {
      final why = correctionBlockedBecause(day('on_leave'));
      // Not "cannot be corrected". Somebody looking at a row wants to
      // know what it is, not only what it is not.
      // `Fmt.label`'s title case, asserted as it actually renders. The
      // first version of this expected 'On leave' and the sentence was
      // reworded to read properly around what the formatter produces.
      expect(why, contains('On Leave'));
    });
  });

  group('what the row says about itself', () {
    test('a corrected day says so, next to the numbers it changed', () {
      final flags = attendanceFlags(
        day('present', inAt: nine, outAt: six, adjusted: true),
      );
      expect(flags, contains('corrected'));
    });

    test('and an ordinary one says nothing at all', () {
      // A column of "not corrected" trains people to stop reading it,
      // which is the same reasoning the zero-late rule already uses.
      expect(attendanceFlags(day('present', inAt: nine, outAt: six)), isNull);
    });
  });
}
