import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:iakauntan/src/core/providers.dart';
import 'package:iakauntan/src/core/theme.dart';
import 'package:iakauntan/src/data/models.dart';
import 'package:iakauntan/src/features/pos/queue_screen.dart';

/// The line at the door.
///
/// The arithmetic is asserted in `supabase/tests/pos_fnb.sql`, against
/// `join_pos_queue` and `pos_queue`. What is asserted here is what a
/// host reads off a tablet while a family stands in front of them: the
/// number, how long they have waited, how many are ahead, and whether
/// this party has already been waiting longer than they were promised.
void main() {
  Map<String, dynamic> entry({
    required int ticket,
    String? name,
    int party = 2,
    String status = 'waiting',
    int waited = 0,
    int? quoted,
    int ahead = 0,
    String? phone,
  }) => {
    'id': 'q$ticket',
    'ticket_no': ticket,
    'name': name,
    'phone': phone,
    'party_size': party,
    'status': status,
    'quoted_minutes': quoted,
    'waited_minutes': waited,
    'ahead': ahead,
    'table_id': null,
    'table_code': null,
    'note': null,
  };

  Widget screen({
    List<Map<String, dynamic>> line = const [],
    bool pos = true,
    int outlets = 1,
  }) => ProviderScope(
    overrides: [
      currentUserProvider.overrideWithValue(null),
      authStateProvider.overrideWith((_) => const Stream<AuthState>.empty()),
      currentOrgProvider.overrideWith(
        (_) async => Organization(
          id: 'o1',
          name: 'Warung Sedap',
          slug: 'warung',
          baseCurrency: 'MYR',
        ),
      ),
      enabledModulesProvider.overrideWith(
        (_) async => pos ? {'pos'} : <String>{},
      ),
      posOutletsProvider.overrideWith(
        (_) async => [
          for (var i = 0; i < outlets; i++)
            {'id': 'out$i', 'name': i == 0 ? 'Bangsar' : 'Cheras'},
        ],
      ),
      posQueueProvider.overrideWith((_, __) async => line),
    ],
    child: MaterialApp(theme: AppTheme.light(), home: const QueueScreen()),
  );

  Future<void> show(WidgetTester tester, Widget w) async {
    tester.view.physicalSize = const Size(900, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(w);
    await tester.pumpAndSettle();
  }

  testWidgets('an empty line says so rather than showing nothing', (
    tester,
  ) async {
    await show(tester, screen());
    expect(find.text('Nobody waiting'), findsOneWidget);
  });

  testWidgets('a party reads as a number, a size and a wait', (tester) async {
    await show(
      tester,
      screen(
        line: [entry(ticket: 7, name: 'Aminah', party: 4, waited: 12,
            quoted: 20, ahead: 2)],
      ),
    );

    expect(find.text('7'), findsOneWidget);
    expect(find.text('Aminah · 4 people'), findsOneWidget);
    expect(
      find.text('12 min waited · told about 20 · 2 ahead'),
      findsOneWidget,
    );
  });

  testWidgets('a party with nobody ahead is told they are next', (
    tester,
  ) async {
    // "0 ahead" is a number a host has to translate. "Next" is not.
    await show(tester, screen(line: [entry(ticket: 1, waited: 3)]));
    expect(find.textContaining('next'), findsOneWidget);
    expect(find.textContaining('0 ahead'), findsNothing);
  });

  testWidgets('a nameless party is still callable by its number', (
    tester,
  ) async {
    await show(tester, screen(line: [entry(ticket: 4, party: 2)]));
    expect(find.text('4'), findsOneWidget);
    // No stray separator where the name would have been.
    expect(find.text('2 people'), findsOneWidget);
  });

  testWidgets('a called party is not offered the call button again', (
    tester,
  ) async {
    await show(
      tester,
      screen(line: [entry(ticket: 2, status: 'called', waited: 8)]),
    );

    expect(find.textContaining('called'), findsOneWidget);
    expect(find.byIcon(Icons.campaign_outlined), findsNothing);
    // Seating them is still one tap away — being called is the step
    // before sitting down, not instead of it.
    expect(find.byIcon(Icons.table_restaurant_outlined), findsOneWidget);
  });

  testWidgets('one shop needs no picker', (tester) async {
    // A picker showing one option is a control that only ever wastes a
    // tap.
    await show(tester, screen(line: [entry(ticket: 1)]));
    expect(find.text('Bangsar'), findsNothing);
  });

  testWidgets('two shops get one', (tester) async {
    await show(tester, screen(line: [entry(ticket: 1)], outlets: 2));
    expect(find.text('Bangsar'), findsOneWidget);
    expect(find.text('Cheras'), findsOneWidget);
  });

  testWidgets('a company with no till is told so rather than shown a line', (
    tester,
  ) async {
    await show(tester, screen(pos: false));
    expect(find.text('The till is not switched on'), findsOneWidget);
  });
}
