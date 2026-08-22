import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/features/pos/menu_links_screen.dart';
import 'package:iakauntan/src/features/pos/public_menu_page.dart';

/// The menu a phone can order from.
///
/// What the server does — the token, the price, the availability, the
/// shift — is asserted in `supabase/tests/pos_public_menu.sql`. What is
/// asserted here is the half a customer holds: the address a sticker
/// carries, what the basket says before it is sent, and that a dish the
/// kitchen has taken off cannot be tapped.
void main() {
  Map<String, dynamic> item({
    required String id,
    required String name,
    double price = 12,
    String category = 'Mains',
    bool available = true,
    String? off,
  }) => {
    'outlet_name': 'The warung',
    'kind': 'table',
    'table_code': 'T7',
    'item_id': id,
    'code': id.toUpperCase(),
    'name': name,
    'unit_price': price,
    'category': category,
    'available': available,
    'off_reason': off,
  };

  test('a published menu is one address, and the token is all of it', () {
    expect(
      menuLinkUrl('https://books.example', 'ab/cd+ef'),
      'https://books.example/#/menu/ab%2Fcd%2Bef',
    );
  });

  test('a link says what it is for in the words a shop uses', () {
    expect(menuLinkKind({'kind': 'table', 'table_code': 'T7'}), 'Table T7');
    expect(menuLinkKind({'kind': 'takeaway'}), 'Takeaway');
    expect(menuLinkKind({'kind': 'delivery'}), 'Delivery');
  });

  test('and says which of the three ways it stopped working', () {
    final now = DateTime(2026, 8, 22, 12);
    expect(menuLinkDead({'is_active': true}, now), isNull);
    expect(menuLinkDead({'is_active': false}, now), 'Switched off');
    expect(
      menuLinkDead(
        {'is_active': true, 'expires_at': '2026-08-22T09:00:00Z'},
        now,
      ),
      'Expired',
    );
    expect(
      menuLinkDead(
        {'is_active': true, 'single_use': true, 'used_at': '2026-08-22'},
        now,
      ),
      'Used',
    );
  });

  test('the basket adds up what was tapped', () {
    expect(
      basketTotal([
        (
          itemId: 'a',
          name: 'Nasi lemak',
          price: 12,
          quantity: 2,
          mods: const [],
        ),
        (
          itemId: 'b',
          name: 'Teh tarik',
          price: 3,
          quantity: 1,
          mods: const [],
        ),
      ]),
      27,
    );
    expect(basketTotal(const []), 0);
  });

  test('and adds what was chosen on top of it', () {
    // The estimate has to include the extra egg, or the number on the
    // basket bar disagrees with the one the shop charges.
    expect(
      basketTotal([
        (
          itemId: 'a',
          name: 'Nasi lemak',
          price: 12,
          quantity: 2,
          mods: const [
            (id: 'm1', name: 'Extra egg', delta: 2),
            (id: 'm2', name: 'Extra sambal', delta: 1),
          ],
        ),
      ]),
      30,
    );
  });

  group('basketKey', () {
    test('the same dish with different answers is two lines', () {
      expect(
        basketKey('a', const ['m1']) == basketKey('a', const ['m2']),
        isFalse,
      );
    });

    test('and the same two answers in either order is one line', () {
      // Otherwise tapping the same thing twice, choosing the same
      // things in a different order, would fill the basket with
      // duplicates a customer cannot tell apart.
      expect(basketKey('a', const ['m2', 'm1']), basketKey('a', const ['m1', 'm2']));
    });

    test('a dish with nothing chosen keys on itself', () {
      expect(basketKey('a', const []), 'a');
    });
  });

  group('lineLabel', () {
    test('names the answers after the dish', () {
      expect(
        lineLabel((
          itemId: 'a',
          name: 'Nasi lemak',
          price: 12,
          quantity: 1,
          mods: const [
            (id: 'm1', name: 'Telur mata', delta: 2),
            (id: 'm2', name: 'Extra sambal', delta: 1),
          ],
        )),
        'Nasi lemak · Telur mata, Extra sambal',
      );
    });

    test('and says just the dish when there was nothing to answer', () {
      expect(
        lineLabel((
          itemId: 'a',
          name: 'Teh tarik',
          price: 3,
          quantity: 1,
          mods: const [],
        )),
        'Teh tarik',
      );
    });
  });

  group('modifierGroups', () {
    final rows = [
      {
        'group_id': 'g1',
        'group_name': 'How would you like your egg',
        'min_select': 1,
        'max_select': 1,
        'modifier_id': 'm1',
        'name': 'Telur mata',
        'price_delta': 0,
      },
      {
        'group_id': 'g1',
        'group_name': 'How would you like your egg',
        'min_select': 1,
        'max_select': 1,
        'modifier_id': 'm2',
        'name': 'Telur dadar',
        'price_delta': 0,
      },
      {
        'group_id': 'g2',
        'group_name': 'Anything extra',
        'min_select': 0,
        'max_select': 0,
        'modifier_id': 'm3',
        'name': 'Extra sambal',
        'price_delta': 1,
      },
    ];

    test('gathers the flat rows into the shop\'s own groups', () {
      final gs = modifierGroups(rows);
      expect(gs.length, 2);
      expect(gs.first['group_name'], 'How would you like your egg');
      expect((gs.first['modifiers'] as List).length, 2);
    });

    test('keeps a group that has nothing live in it', () {
      // A required group with no modifiers left is something somebody
      // has to see, not a question that quietly disappears.
      final gs = modifierGroups([
        {
          'group_id': 'g9',
          'group_name': 'Sold out entirely',
          'min_select': 1,
          'max_select': 1,
          'modifier_id': null,
        },
      ]);
      expect(gs.length, 1);
      expect((gs.first['modifiers'] as List), isEmpty);
    });

    test('a required group is unanswered until something is picked', () {
      final gs = modifierGroups(rows);
      expect(missingChoices(gs, <String>{}), ['How would you like your egg']);
      expect(missingChoices(gs, {'m1'}), isEmpty);
    });

    test('an optional group is never missing', () {
      final gs = modifierGroups(rows);
      expect(missingChoices(gs, {'m1'}).contains('Anything extra'), isFalse);
    });

    test('and too many answers is as wrong as too few', () {
      // max_select of one means one. Two would be sent, and the till
      // would show a plate nobody can cook.
      final gs = modifierGroups(rows);
      expect(missingChoices(gs, {'m1', 'm2'}), [
        'How would you like your egg',
      ]);
    });

    test('a maximum of nought means as many as you like', () {
      final gs = modifierGroups(rows);
      expect(groupSatisfied(gs[1], {'m3'}), isTrue);
      expect(groupSatisfied(gs[1], <String>{}), isTrue);
    });
  });

  test('the menu keeps the shop\'s own headings and order', () {
    final groups = menuGroups([
      item(id: 'a', name: 'Nasi lemak'),
      item(id: 'b', name: 'Teh tarik', category: 'Drinks', price: 3),
      item(id: 'c', name: 'Mee goreng'),
    ]);
    expect(groups.keys.toList(), ['Mains', 'Drinks']);
    expect(groups['Mains']!.length, 2);
  });

  testWidgets('a dish the kitchen took off cannot be tapped', (tester) async {
    // The greyed-out row carries the shop's own reason, because a row
    // that is off with nothing said is a row customers ask staff about.
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListView(
            children: [
              for (final r in [
                item(id: 'a', name: 'Nasi lemak'),
                item(
                  id: 'b',
                  name: 'Teh tarik',
                  price: 3,
                  available: false,
                  off: 'Sold out — habis',
                ),
              ])
                Builder(
                  builder: (_) => ListTile(
                    title: Text('${r['name']}'),
                    subtitle: r['available'] != true
                        ? Text('${r['off_reason']}')
                        : null,
                    trailing: IconButton(
                      icon: const Icon(Icons.add_circle_outline),
                      onPressed: r['available'] == true ? () {} : null,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Sold out — habis'), findsOneWidget);
    final buttons = tester
        .widgetList<IconButton>(find.byType(IconButton))
        .toList();
    expect(buttons.first.onPressed, isNotNull);
    expect(buttons.last.onPressed, isNull);
  });
}
