import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/features/pos/menu_times_screen.dart';

/// When each part of the menu is offered.
///
/// The window arithmetic is asserted in `supabase/tests/pos_fnb.sql`,
/// against `app.pos_window_open` — including the case that gets written
/// backwards, a bar open from ten at night until two in the morning.
///
/// What is asserted here is the sentence a shopkeeper checks their own
/// breakfast against. Getting it wrong means finding out at eleven
/// o'clock, from a customer.
void main() {
  Map<String, dynamic> schedule({
    List<int>? weekdays,
    String? from,
    String? to,
  }) => {
    'name': 'Breakfast',
    'weekdays': weekdays,
    'starts_at': from,
    'ends_at': to,
  };

  test('no days and no hours reads as always', () {
    expect(scheduleWhen(schedule()), isNull);
  });

  test('hours drop the seconds Postgres sends', () {
    expect(
      scheduleWhen(schedule(from: '07:00:00', to: '11:00:00')),
      '07:00–11:00',
    );
  });

  test('weekdays are named, Monday first', () {
    expect(scheduleWhen(schedule(weekdays: [1, 2, 3])), 'Mon Tue Wed');
  });

  test('all seven days is the same as none, and says nothing', () {
    // A row spelling out every day buries the part that matters, and
    // it is not telling the reader anything they did not assume.
    expect(scheduleWhen(schedule(weekdays: [1, 2, 3, 4, 5, 6, 7])), isNull);
  });

  test('a weekend brunch reads as one line', () {
    expect(
      scheduleWhen(
        schedule(weekdays: [6, 7], from: '09:00:00', to: '14:30:00'),
      ),
      'Sat Sun · 09:00–14:30',
    );
  });

  test('a window that crosses midnight is shown as written', () {
    // Not reordered into "02:00–22:00", which would read as a fourteen
    // hour daytime window rather than a late bar. The server knows what
    // it means; the screen must not tidy it into a lie.
    expect(
      scheduleWhen(schedule(from: '22:00:00', to: '02:00:00')),
      '22:00–02:00',
    );
  });

  test('hours with no days still say the hours', () {
    expect(scheduleWhen(schedule(from: '11:30:00', to: '15:00:00')),
        '11:30–15:00');
  });
}
