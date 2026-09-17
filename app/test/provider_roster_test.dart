import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iakauntan/src/features/pos/provider_roster.dart';

({TimeOfDay? start, TimeOfDay? end}) block(int fromH, int toH) => (
  start: TimeOfDay(hour: fromH, minute: 0),
  end: TimeOfDay(hour: toH, minute: 0),
);

void main() {
  group('the days', () {
    test('are numbered the way extract(isodow) numbers them', () {
      // 0217 states it rather than assuming it, because half the world
      // starts the week on Sunday and the other half does not.
      expect(weekdayName(1), 'Monday');
      expect(weekdayName(7), 'Sunday');
      expect(kIsoWeek, [1, 2, 3, 4, 5, 6, 7]);
    });

    test('and shorten to three letters', () {
      expect(weekdayShort(3), 'Wed');
      expect(weekdayShort(6), 'Sat');
    });
  });

  group('a time on the wire', () {
    test('is what a Postgres time column takes', () {
      expect(wireTime(const TimeOfDay(hour: 9, minute: 0)), '09:00:00');
      expect(wireTime(const TimeOfDay(hour: 18, minute: 30)), '18:30:00');
    });

    test('and comes back the same', () {
      expect(parseWireTime('09:00:00'), const TimeOfDay(hour: 9, minute: 0));
      expect(parseWireTime('18:30'), const TimeOfDay(hour: 18, minute: 30));
    });

    test('anything that is not one is nothing', () {
      expect(parseWireTime(null), isNull);
      expect(parseWireTime(''), isNull);
      expect(parseWireTime('nine'), isNull);
      expect(parseWireTime('99:00:00'), isNull);
      expect(parseWireTime('09:99:00'), isNull);
    });
  });

  group('a block of hours', () {
    test('runs forwards or it is not a block', () {
      // pos_provider_hours_order_ck is `ends_at > starts_at`.
      expect(
        hoursRunForward(
          const TimeOfDay(hour: 9, minute: 0),
          const TimeOfDay(hour: 18, minute: 0),
        ),
        isTrue,
      );
      expect(
        hoursRunForward(
          const TimeOfDay(hour: 18, minute: 0),
          const TimeOfDay(hour: 9, minute: 0),
        ),
        isFalse,
      );
    });

    test('and a day of no length is not a day worked', () {
      expect(
        hoursRunForward(
          const TimeOfDay(hour: 9, minute: 0),
          const TimeOfDay(hour: 9, minute: 0),
        ),
        isFalse,
      );
    });

    test('minutes count, not only hours', () {
      expect(
        hoursRunForward(
          const TimeOfDay(hour: 9, minute: 30),
          const TimeOfDay(hour: 9, minute: 31),
        ),
        isTrue,
      );
      expect(
        hoursRunForward(
          const TimeOfDay(hour: 9, minute: 31),
          const TimeOfDay(hour: 9, minute: 30),
        ),
        isFalse,
      );
    });
  });

  group('why a week cannot be saved', () {
    test('a day with a start and no end is named', () {
      expect(
        weekBlockedBecause({2: (start: const TimeOfDay(hour: 9, minute: 0), end: null)}),
        'Tuesday needs both a start and an end.',
      );
    });

    test('and a day with an end and no start', () {
      expect(
        weekBlockedBecause({5: (start: null, end: const TimeOfDay(hour: 18, minute: 0))}),
        'Friday needs both a start and an end.',
      );
    });

    test('a day that ends before it starts is refused as the check does', () {
      expect(
        weekBlockedBecause({6: block(18, 9)}),
        'Saturday ends before it starts.',
      );
    });

    test('an empty week is allowed to be saved', () {
      // Clearing somebody down to nothing is a thing a salon does when
      // a stylist leaves. It is not an error; it is a refusal to book
      // them, which is exactly right.
      expect(weekBlockedBecause(const {}), isNull);
    });

    test('a day left blank entirely is not half filled in', () {
      expect(weekBlockedBecause({3: (start: null, end: null)}), isNull);
    });

    test('the earliest broken day is the one named', () {
      expect(
        weekBlockedBecause({
          6: block(18, 9),
          2: (start: const TimeOfDay(hour: 9, minute: 0), end: null),
        }),
        'Tuesday needs both a start and an end.',
      );
    });

    test('a whole good week is not blocked', () {
      expect(
        weekBlockedBecause({1: block(9, 18), 2: block(9, 18)}),
        isNull,
      );
    });
  });

  group('the week as rows', () {
    test('carries only the days that were filled in', () {
      final rows = weekRows({
        1: block(9, 18),
        3: (start: const TimeOfDay(hour: 10, minute: 30), end: null),
        7: block(11, 16),
      });
      expect(rows.length, 2);
      expect(rows.first, {
        'weekday': 1,
        'starts_at': '09:00:00',
        'ends_at': '18:00:00',
      });
      expect(rows.last['weekday'], 7);
    });

    test('in the order the week runs', () {
      final rows = weekRows({6: block(9, 13), 1: block(9, 18)});
      expect([for (final r in rows) r['weekday']], [1, 6]);
    });

    test('and an empty week is no rows at all', () {
      expect(weekRows(const {}), isEmpty);
    });
  });

  group('the week as it came back', () {
    test('reads into days that can be edited', () {
      final week = weekFromRows([
        {'weekday': 1, 'starts_at': '09:00:00', 'ends_at': '18:00:00'},
        {'weekday': 6, 'starts_at': '10:00:00', 'ends_at': '14:00:00'},
      ]);
      expect(week.keys.toList(), [1, 6]);
      expect(week[1]!.start, const TimeOfDay(hour: 9, minute: 0));
      expect(week[6]!.end, const TimeOfDay(hour: 14, minute: 0));
    });

    test('and keeps the earlier of two blocks on one day', () {
      // The table allows a morning and an evening. The editor shows
      // one, and showing the later one would look like the morning had
      // been lost.
      final week = weekFromRows([
        {'weekday': 2, 'starts_at': '09:00:00', 'ends_at': '12:00:00'},
        {'weekday': 2, 'starts_at': '17:00:00', 'ends_at': '21:00:00'},
      ]);
      expect(week[2]!.start, const TimeOfDay(hour: 9, minute: 0));
    });

    test('a row for no weekday there is is dropped', () {
      expect(
        weekFromRows([
          {'weekday': 0, 'starts_at': '09:00:00', 'ends_at': '18:00:00'},
          {'weekday': 8, 'starts_at': '09:00:00', 'ends_at': '18:00:00'},
        ]),
        isEmpty,
      );
    });

    test('and a row with a time nobody can read is dropped', () {
      expect(
        weekFromRows([
          {'weekday': 1, 'starts_at': 'morning', 'ends_at': '18:00:00'},
        ]),
        isEmpty,
      );
    });
  });

  group('whether anybody can be booked at all', () {
    test('an empty week is open at no time', () {
      // app.pos_provider_is_open is an `exists` over the hours table.
      // No rows, no hours, and book_appointment refuses every slot
      // with "Siti does not work then, or is away."
      expect(providerCanBeBooked(const []), isFalse);
    });

    test('and one day is enough to be bookable', () {
      expect(
        providerCanBeBooked([
          {'weekday': 1, 'starts_at': '09:00:00', 'ends_at': '18:00:00'},
        ]),
        isTrue,
      );
    });
  });

  group('what a provider row says', () {
    test('the days they keep', () {
      expect(
        rosterSummary([
          {'weekday': 1, 'starts_at': '09:00:00', 'ends_at': '18:00:00'},
          {'weekday': 2, 'starts_at': '09:00:00', 'ends_at': '18:00:00'},
          {'weekday': 6, 'starts_at': '10:00:00', 'ends_at': '14:00:00'},
        ]),
        'Mon, Tue, Sat',
      );
    });

    test('and says plainly when there are none', () {
      expect(
        rosterSummary(const []),
        'Works no hours — every booking will be refused',
      );
    });

    test('in week order, whatever order the rows arrived in', () {
      expect(
        rosterSummary([
          {'weekday': 7, 'starts_at': '10:00:00', 'ends_at': '14:00:00'},
          {'weekday': 1, 'starts_at': '09:00:00', 'ends_at': '18:00:00'},
        ]),
        'Mon, Sun',
      );
    });
  });

  test('one day reads as a span', () {
    expect(
      hoursLine(
        const TimeOfDay(hour: 9, minute: 0),
        const TimeOfDay(hour: 18, minute: 30),
      ),
      '09:00–18:30',
    );
  });

  group('why time off cannot be recorded', () {
    final from = DateTime(2026, 8, 30, 9);

    test('without both ends of it', () {
      expect(
        timeOffBlockedBecause(from, null),
        'Time off needs a start and an end.',
      );
      expect(
        timeOffBlockedBecause(null, from),
        'Time off needs a start and an end.',
      );
    });

    test('running backwards, which is what the check refuses', () {
      expect(
        timeOffBlockedBecause(from, DateTime(2026, 8, 29)),
        'It ends before it starts.',
      );
    });

    test('or the same instant twice', () {
      expect(timeOffBlockedBecause(from, from), 'It ends before it starts.');
    });

    test('a real spell is not blocked', () {
      expect(timeOffBlockedBecause(from, DateTime(2026, 9, 3)), isNull);
    });
  });

  group('whether a spell is over', () {
    final now = DateTime(2026, 8, 30, 12);

    test('one that ended is', () {
      expect(timeOffIsPast(DateTime(2026, 8, 29), now), isTrue);
    });

    test('one still running is not', () {
      expect(timeOffIsPast(DateTime(2026, 8, 31), now), isFalse);
    });

    test('and one ending this instant is not yet', () {
      expect(timeOffIsPast(now, now), isFalse);
    });
  });
}
