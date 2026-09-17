import 'package:flutter/material.dart';

/// Who does the work, when they work, and when they are away.
///
/// `posServiceProvidersProvider` was watched by nothing, and
/// `pos_provider_hours` and `pos_provider_time_off` had no reader or
/// writer at all. That is not a missing convenience. `book_appointment`
/// asks `app.pos_provider_is_open`, which is an `exists` over the hours
/// table — so a provider whose week nobody has entered is open at no
/// time, and every booking made for them is refused with "Siti does
/// not work then, or is away." A salon's diary was dead on arrival and
/// the sentence it died with blamed Siti.

/// The days, as `extract(isodow)` numbers them.
///
/// 0217 states it rather than assuming it, "because half the world
/// starts the week on Sunday and the other half does not": 1 is
/// Monday and 7 is Sunday.
const List<int> kIsoWeek = [1, 2, 3, 4, 5, 6, 7];

String weekdayName(int isodow) => switch (isodow) {
  1 => 'Monday',
  2 => 'Tuesday',
  3 => 'Wednesday',
  4 => 'Thursday',
  5 => 'Friday',
  6 => 'Saturday',
  7 => 'Sunday',
  _ => '$isodow',
};

String weekdayShort(int isodow) => weekdayName(isodow).substring(0, 3);

/// A `time` column, as Postgres wants one.
String wireTime(TimeOfDay t) =>
    '${t.hour.toString().padLeft(2, '0')}:'
    '${t.minute.toString().padLeft(2, '0')}:00';

/// And back again. Null for anything that is not one.
TimeOfDay? parseWireTime(Object? v) {
  final s = '${v ?? ''}';
  if (s.length < 5) return null;
  final h = int.tryParse(s.substring(0, 2));
  final m = int.tryParse(s.substring(3, 5));
  if (h == null || m == null) return null;
  if (h < 0 || h > 23 || m < 0 || m > 59) return null;
  return TimeOfDay(hour: h, minute: m);
}

int _minutes(TimeOfDay t) => t.hour * 60 + t.minute;

/// Whether a block runs forwards, which is `pos_provider_hours_order_ck`.
///
/// A block ending when it starts is refused too: the constraint is
/// `ends_at > starts_at`, and a zero-length day is not a day worked.
bool hoursRunForward(TimeOfDay start, TimeOfDay end) =>
    _minutes(end) > _minutes(start);

/// Why a week cannot be saved, in the terms the table refuses it in.
///
/// A day with no end is the commonest way to end up with a provider
/// who cannot be booked at all, so it is named rather than dropped.
String? weekBlockedBecause(Map<int, ({TimeOfDay? start, TimeOfDay? end})> week) {
  for (final day in kIsoWeek) {
    final block = week[day];
    if (block == null) continue;
    final start = block.start, end = block.end;
    if (start == null && end == null) continue;
    if (start == null || end == null) {
      return '${weekdayName(day)} needs both a start and an end.';
    }
    if (!hoursRunForward(start, end)) {
      return '${weekdayName(day)} ends before it starts.';
    }
  }
  return null;
}

/// The week as rows, ready for `pos_provider_hours`.
///
/// A day left blank is a day not worked, and it is simply absent — the
/// table has no way to say "works no hours on Wednesday" and does not
/// need one.
List<Map<String, dynamic>> weekRows(
  Map<int, ({TimeOfDay? start, TimeOfDay? end})> week,
) => [
  for (final day in kIsoWeek)
    if (week[day]?.start != null && week[day]?.end != null)
      {
        'weekday': day,
        'starts_at': wireTime(week[day]!.start!),
        'ends_at': wireTime(week[day]!.end!),
      },
];

/// The week as it came back, ready to be edited.
Map<int, ({TimeOfDay? start, TimeOfDay? end})> weekFromRows(
  Iterable<Map<String, dynamic>> rows,
) {
  final week = <int, ({TimeOfDay? start, TimeOfDay? end})>{};
  for (final r in rows) {
    final day = int.tryParse('${r['weekday']}');
    if (day == null || !kIsoWeek.contains(day)) continue;
    final start = parseWireTime(r['starts_at']);
    final end = parseWireTime(r['ends_at']);
    if (start == null || end == null) continue;
    // The first block of the day. A provider with two blocks — a
    // morning and an evening — keeps both in the table, and this
    // editor shows the earlier one rather than pretending the later
    // one is not there.
    week.putIfAbsent(day, () => (start: start, end: end));
  }
  return week;
}

/// Whether anybody can be booked with this provider at all.
///
/// The whole of the defect in one line: `exists` over no rows is
/// false, so a provider with an empty week refuses every hour of it.
bool providerCanBeBooked(Iterable<Map<String, dynamic>> hours) =>
    hours.isNotEmpty;

/// What a provider's row says under their name.
String rosterSummary(Iterable<Map<String, dynamic>> hours) {
  final week = weekFromRows(hours);
  if (week.isEmpty) return 'Works no hours — every booking will be refused';
  final days = [for (final d in kIsoWeek) if (week.containsKey(d)) d];
  return days.map(weekdayShort).join(', ');
}

/// One day's line.
String hoursLine(TimeOfDay start, TimeOfDay end) =>
    '${wireTime(start).substring(0, 5)}–${wireTime(end).substring(0, 5)}';

/// Why a spell of time off cannot be recorded.
///
/// `pos_provider_time_off_order_ck` is `ends_at > starts_at`, and the
/// same instant twice is not time off.
String? timeOffBlockedBecause(DateTime? from, DateTime? to) {
  if (from == null || to == null) return 'Time off needs a start and an end.';
  if (!to.isAfter(from)) return 'It ends before it starts.';
  return null;
}

/// Whether a spell of time off is over.
///
/// Past spells are kept rather than tidied away: a booking refused in
/// March was refused for a reason, and the reason is this row.
bool timeOffIsPast(DateTime endsAt, DateTime now) => endsAt.isBefore(now);
