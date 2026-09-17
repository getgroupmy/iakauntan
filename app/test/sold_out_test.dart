import 'package:flutter_test/flutter_test.dart';
import 'package:iakauntan/src/features/pos/sold_out_dialog.dart';

Map<String, dynamic> stop({
  String code = 'F12',
  String name = 'Nasi lemak ayam',
  String reason = 'Sold out',
  String by = 'Aisyah',
  String? at = '2026-08-31T03:20:00Z',
}) => <String, dynamic>{
  'item_id': 'i1',
  'code': code,
  'name': name,
  'reason': reason,
  'stopped_by': by,
  'stopped_at': at,
};

void main() {
  group('what a stopped dish reads as', () {
    test('its code and its name', () {
      expect(stoppedItemLabel(stop()), 'F12 Nasi lemak ayam');
    });

    test('a dish with no code still reads', () {
      expect(stoppedItemLabel(stop(code: '')), 'Nasi lemak ayam');
    });
  });

  group('who took it off, and why', () {
    test('the reason, the person and the time', () {
      final s = stoppedBecause(stop());
      expect(s, contains('Sold out'));
      expect(s, contains('Aisyah'));
      expect(s, contains(':'));
    });

    test('the function already answers both, so nothing is invented', () {
      // An untyped reason comes back as "Sold out" and a leaver as
      // "Somebody who has left".
      final s = stoppedBecause(
        stop(reason: 'Sold out', by: 'Somebody who has left'),
      );
      expect(s, contains('Somebody who has left'));
    });

    test('a time that will not parse is left out, not shown as a dash', () {
      // An em dash between two real facts reads as a missing third
      // one, which is worse than three words where there were four.
      final s = stoppedBecause(stop(at: null));
      expect(s, 'Sold out · Aisyah');
      expect(s, isNot(contains('—')));
    });

    test('a row missing everything does not read as a row of separators', () {
      expect(
        stoppedBecause(<String, dynamic>{}),
        isEmpty,
      );
    });
  });

  test('the list says it is a day’s list', () {
    // pos_stopped_items filters on today in Kuala Lumpur and nothing
    // else, so an empty list means the kitchen has everything.
    expect(soldOutScope, contains('today'));
    expect(soldOutScope, contains('tomorrow'));
  });
}
