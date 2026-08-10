import 'package:flutter_test/flutter_test.dart';
import 'package:iakauntan/src/core/format.dart';

/// The formatting layer is what every figure on screen passes through,
/// so a change here shows up on a payslip.
void main() {
  group('money', () {
    test('uses the Malaysian convention', () {
      expect(Fmt.money(19332), 'RM 19,332.00');
      expect(Fmt.money(0), 'RM 0.00');
      expect(Fmt.money(-3745), 'RM -3,745.00');
    });

    test('keeps sen', () {
      expect(Fmt.money(1255.20), 'RM 1,255.20');
      expect(Fmt.money(87.5), 'RM 87.50');
    });
  });

  group('days', () {
    test('trims a trailing zero but keeps a half day', () {
      expect(Fmt.days(16), '16');
      expect(Fmt.days(10.5), '10.5');
      expect(Fmt.days(0), '0');
    });
  });

  group('numbers off the wire', () {
    test('parses what PostgREST sends for numeric columns', () {
      // numeric arrives as a string, not a double.
      expect(Fmt.toDouble('1255.20'), 1255.20);
      expect(Fmt.toDouble(1255.2), 1255.20);
      expect(Fmt.toDouble(null), 0);
      expect(Fmt.toDouble('not a number'), 0);
    });

    test('parses integers', () {
      expect(Fmt.toInt('3'), 3);
      expect(Fmt.toInt(null), 0);
    });
  });

  group('dates', () {
    test('reads a date column and a timestamptz', () {
      expect(Fmt.parseDate('2026-01-31'), DateTime.parse('2026-01-31'));
      expect(Fmt.parseDate(null), isNull);
      expect(Fmt.parseDate(''), isNull);
    });

    test('formats the way a Malaysian document reads', () {
      expect(Fmt.date(DateTime(2026, 1, 31)), '31/01/2026');
    });
  });

  group('labels', () {
    test('turns a database enum into something readable', () {
      expect(Fmt.label('not_applicable'), 'Not Applicable');
      expect(Fmt.label('posted'), 'Posted');
    });
  });

  test('initials take the first and last name', () {
    expect(Fmt.initials('Nurul Aisyah binti Rahman'), 'NR');
    expect(Fmt.initials('Demo User'), 'DU');
    expect(Fmt.initials('Prince'), isNotEmpty);
    expect(Fmt.initials(null), isNotEmpty);
  });
}
