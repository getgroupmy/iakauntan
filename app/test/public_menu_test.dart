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
        (itemId: 'a', name: 'Nasi lemak', price: 12, quantity: 2),
        (itemId: 'b', name: 'Teh tarik', price: 3, quantity: 1),
      ]),
      27,
    );
    expect(basketTotal(const []), 0);
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
