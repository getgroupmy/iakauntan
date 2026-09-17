import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iakauntan/src/features/pos/channels.dart';

/// How an order arrived, in the words a cashier reads.
///
/// The labels are wording rather than data and live in Dart on purpose:
/// the enum is the fact, and a shop that calls takeaway "bungkus" is
/// changing what a screen says, not what a report groups by.
///
/// That separation has a cost, and it is what this file exists for. A
/// migration adding a channel does not touch the map, and nothing said
/// so — `channelLabel` falls back to the raw value, so the ninth channel
/// would reach a cashier's chip reading `mobile_app`. Read out of
/// `0229` rather than copied, because a copied list is one that drifts
/// silently, which is exactly the failure being guarded against.
void main() {
  test('every channel the database has, this screen has words for', () {
    final sql = File('../supabase/migrations/0229_how_the_order_arrived.sql')
        .readAsStringSync();
    final block = RegExp(
      r"create type app\.pos_order_channel as enum \(([^)]*)\)",
      multiLine: true,
    ).firstMatch(sql);
    expect(block, isNotNull, reason: 'the enum moved; this test is stale');

    final inSql = RegExp("'([a-z_]+)'")
        .allMatches(block!.group(1)!)
        .map((m) => m.group(1)!)
        .toSet();
    // Guards the regular expression itself: an expression that matched
    // nothing would make every claim below vacuously true.
    expect(inSql.length, greaterThan(4));

    expect(posOrderChannels.keys.toSet(), inSql);
  });

  test('and no words for a channel it does not have', () {
    // The other direction. A label left behind by a migration that
    // dropped a channel offers a filter nothing can ever match.
    final sql = File('../supabase/migrations/0229_how_the_order_arrived.sql')
        .readAsStringSync();
    for (final code in posOrderChannels.keys) {
      expect(sql.contains("'$code'"), isTrue, reason: code);
    }
  });

  group('what a chip says', () {
    test('is the label, where there is one', () {
      expect(channelLabel('dine_in'), 'Dine-in');
      expect(channelLabel('mobile_app'), 'Mobile app');
    });

    test('and the raw value where there is not, rather than nothing', () {
      // Ugly on purpose. A blank chip is a bill that looks like it
      // arrived by no route at all; `something_new` at least names what
      // to go and look for.
      expect(channelLabel('something_new'), 'something_new');
      expect(channelLabel(null), 'null');
    });
  });

  group('and the icon beside it', () {
    test('is its own for every channel that has one', () {
      // Distinctness is the point of an icon. Two channels sharing one
      // makes the chip decorative.
      final icons = <IconData>{};
      for (final code in posOrderChannels.keys) {
        if (code == 'walk_in') continue; // shares the fallback, see below
        icons.add(channelIcon(code));
      }
      expect(icons.length, posOrderChannels.length - 1);
    });

    test('and a shopfront for a walk-in, which is also the fallback', () {
      // Recorded rather than treated as a clash: somebody who walked in
      // is the ordinary case, and a channel this screen has never heard
      // of is most likely one too.
      expect(channelIcon('walk_in'), channelIcon('something_new'));
      expect(channelIcon(null), channelIcon('walk_in'));
      // Named, not just "the same as each other". A question mark would
      // also satisfy that, and it says something different to a cashier
      // — that the bill is a puzzle rather than an ordinary sale.
      expect(channelIcon('walk_in'), Icons.storefront_outlined);
    });
  });
}
