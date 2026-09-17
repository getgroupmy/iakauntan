import 'package:flutter_test/flutter_test.dart';
import 'package:iakauntan/src/features/pos/channels.dart';

/// A warung that takes people at the counter, at a table, and on a bike.
List<Map<String, dynamic>> accepted() => [
  {'channel': 'walk_in', 'is_active': true, 'is_default': false},
  {'channel': 'dine_in', 'is_active': true, 'is_default': true},
  {'channel': 'delivery', 'is_active': true, 'is_default': false},
  {'channel': 'phone', 'is_active': false, 'is_default': false},
];

Map<String, dynamic> till({String? channel, String outlet = 'o1'}) => {
  'id': 't1',
  'name': 'Kiosk',
  'default_channel': channel,
  'pos_outlets': {'id': outlet, 'name': 'Jalan Ampang'},
};

void main() {
  group('what a till may be set to', () {
    test('only what the shop accepts', () {
      // set_pos_sale_channel checks the outlet's list; a default
      // outside it would put a row in the day's report that can only
      // be a mistake.
      expect(choosableChannels(accepted()), [
        'walk_in',
        'dine_in',
        'delivery',
      ]);
    });

    test('a channel switched off is not on offer', () {
      expect(choosableChannels(accepted()), isNot(contains('phone')));
    });

    test('a shop that accepts nothing offers nothing', () {
      expect(choosableChannels(const []), isEmpty);
    });
  });

  group("the shop's own default", () {
    test('is the one marked as such', () {
      expect(outletDefaultChannel(accepted()), 'dine_in');
    });

    test('and a default that has been switched off is not one', () {
      expect(
        outletDefaultChannel([
          {'channel': 'phone', 'is_active': false, 'is_default': true},
        ]),
        isNull,
      );
    });

    test('a shop that has never chosen has none', () {
      expect(
        outletDefaultChannel([
          {'channel': 'walk_in', 'is_active': true, 'is_default': false},
        ]),
        isNull,
      );
    });
  });

  group('what a sale opened on this till will be', () {
    test('what the till says, when it says something', () {
      expect(registerAssumption(till(channel: 'takeaway'), accepted()),
          'takeaway');
    });

    test("else what the shop says", () {
      expect(registerAssumption(till(), accepted()), 'dine_in');
    });

    test('else walk-in', () {
      // The three steps app.pos_sale_channel_default takes on insert,
      // in that order.
      expect(registerAssumption(till(), const []), 'walk_in');
    });
  });

  group('whether the till says something the shop does not', () {
    test('it does when it has been set', () {
      expect(registerOverrides(till(channel: 'takeaway')), isTrue);
    });

    test('and a blank is not "no channel"', () {
      // A blank field on a till is the outlet's channel, which is why
      // the row shows the resolved answer rather than the setting.
      expect(registerOverrides(till()), isFalse);
    });
  });

  group("what a till's row says", () {
    test('names the channel and says the till chose it', () {
      expect(
        registerChannelLine(till(channel: 'takeaway'), accepted()),
        'Takeaway — set on this till',
      );
    });

    test('and says so when the shop chose it', () {
      expect(
        registerChannelLine(till(), accepted()),
        'Dine-in — whatever the shop says',
      );
    });

    test('a shop with no default still resolves to walk-in', () {
      expect(
        registerChannelLine(till(), const []),
        'Walk-in — whatever the shop says',
      );
    });
  });

  group('the tills standing in one shop', () {
    test('are the ones whose outlet it is', () {
      final all = [
        till(outlet: 'o1'),
        {...till(outlet: 'o2'), 'id': 't2'},
      ];
      expect(registersAt(all, 'o1').length, 1);
      expect(registersAt(all, 'o1').first['id'], 't1');
    });

    test('and a till whose outlet did not come back is not one of them', () {
      // The embed can be absent when the select is narrowed; a till
      // shown under the wrong shop is worse than one not shown.
      expect(registersAt([{'id': 't3', 'name': 'Counter'}], 'o1'), isEmpty);
    });

    test('a shop with no tills has none', () {
      expect(registersAt([till(outlet: 'o2')], 'o1'), isEmpty);
    });
  });
}
