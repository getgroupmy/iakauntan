import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/core/providers.dart';
import 'package:iakauntan/src/core/theme.dart';
import 'package:iakauntan/src/features/pos/diary_screen.dart';

/// The diary.
///
/// That a slot cannot be sold twice is asserted in
/// `supabase/tests/pos_service.sql`, against the exclusion constraint
/// that enforces it. What is asserted here is what the person on the
/// front desk sees — above all that somebody with an empty day still
/// has a column, because "who is free at three" is the question a
/// diary is opened to answer and a list of only busy people cannot
/// answer it.
void main() {
  Map<String, dynamic> register() => {
    'id': 'reg-1',
    'code': 'T1',
    'name': 'Front desk',
    'is_active': true,
    'pos_outlets': {
      'id': 'out-1',
      'name': 'The salon',
      'code': 'SALON',
      'business_type': 'service',
    },
  };

  /// A provider with no booking: the left join gives one row with every
  /// booking column null, which is what an empty column looks like.
  Map<String, dynamic> free({
    String id = 'p-1',
    String name = 'Aida',
  }) => {
    'provider_id': id,
    'provider': name,
    'booking_id': null,
    'starts_at': null,
    'ends_at': null,
    'minutes': null,
    'status': null,
    'customer': null,
    'description': null,
    'price': null,
    'sale_id': null,
  };

  Map<String, dynamic> booking({
    String providerId = 'p-1',
    String provider = 'Aida',
    String id = 'b-1',
    String status = 'booked',
    String customer = 'Siti',
    String what = 'Haircut',
    int minutes = 45,
    num price = 45,
  }) => {
    'provider_id': providerId,
    'provider': provider,
    'booking_id': id,
    'starts_at': '2026-08-19T02:00:00Z',
    'ends_at': '2026-08-19T02:45:00Z',
    'minutes': minutes,
    'status': status,
    'customer': customer,
    'description': what,
    'price': '$price',
    'sale_id': null,
  };

  Widget harness({
    List<Map<String, dynamic>> registers = const [],
    List<Map<String, dynamic>> sheet = const [],
  }) => ProviderScope(
    overrides: [
      posRegistersProvider.overrideWith((_) async => registers),
      posDaySheetProvider.overrideWith((_, __) async => sheet),
      posServicesProvider.overrideWith((_) async => const []),
    ],
    child: MaterialApp(theme: AppTheme.light(), home: const DiaryScreen()),
  );

  testWidgets('an outlet with nobody to book says so', (tester) async {
    await tester.pumpWidget(harness(registers: [register()]));
    await tester.pumpAndSettle();

    expect(find.text('Nobody to book'), findsOneWidget);
  });

  testWidgets('a provider with an empty day still gets a column', (
    tester,
  ) async {
    await tester.pumpWidget(
      harness(registers: [register()], sheet: [free()]),
    );
    await tester.pumpAndSettle();

    expect(find.text('Aida'), findsOneWidget);
    // Said in words. A blank column reads as "not loaded"; this is the
    // good answer and has to look like one.
    expect(find.text('Free all day'), findsOneWidget);
  });

  testWidgets('a booked slot names the customer, the length and the price', (
    tester,
  ) async {
    await tester.pumpWidget(
      harness(registers: [register()], sheet: [booking()]),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('Haircut'), findsOneWidget);
    expect(find.text('Siti · 45m · RM 45.00'), findsOneWidget);
    expect(find.text('Check in'), findsOneWidget);
  });

  testWidgets('somebody already in is not offered a second check-in', (
    tester,
  ) async {
    await tester.pumpWidget(
      harness(
        registers: [register()],
        sheet: [booking(status: 'arrived')],
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Check in'), findsNothing);
    expect(find.text('In'), findsOneWidget);
  });

  testWidgets('a cancelled slot stays on the day, struck through', (
    tester,
  ) async {
    await tester.pumpWidget(
      harness(
        registers: [register()],
        sheet: [booking(status: 'cancelled')],
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Cancelled'), findsOneWidget);
    // The hour is free again, but the day has to show it was sold once.
    final title = tester.widget<Text>(find.textContaining('Haircut'));
    expect(title.style?.decoration, TextDecoration.lineThrough);
  });

  testWidgets('two providers are two columns, busy or not', (tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      harness(
        registers: [register()],
        sheet: [
          booking(),
          free(id: 'p-2', name: 'Faiz'),
        ],
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Aida'), findsOneWidget);
    expect(find.text('Faiz'), findsOneWidget);
    expect(find.text('Free all day'), findsOneWidget);
  });

  testWidgets('today offers no button to go to today', (tester) async {
    await tester.pumpWidget(
      harness(registers: [register()], sheet: [free()]),
    );
    await tester.pumpAndSettle();

    expect(find.text('Today'), findsNothing);

    // Move a day, and the way back appears.
    await tester.tap(find.byIcon(Icons.chevron_right));
    await tester.pumpAndSettle();
    expect(find.text('Today'), findsOneWidget);
  });
}
