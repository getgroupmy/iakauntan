import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/core/theme.dart';
import 'package:iakauntan/src/features/pos/modifier_sheet.dart';

/// The questions a plate comes with.
///
/// What a modifier does to the money is asserted in
/// `supabase/tests/pos_fnb.sql`, against `add_line_modifier`. What is
/// asserted here is the thing a screen is uniquely able to get wrong:
/// letting somebody past a question the database will refuse to accept,
/// with a queue behind them.
void main() {
  Map<String, dynamic> option({
    required String group,
    required String groupName,
    required int min,
    int? max,
    required String id,
    required String name,
    num delta = 0,
    bool isDefault = false,
  }) => {
    'group_id': group,
    'group_name': groupName,
    'min_select': min,
    'max_select': max,
    'modifier_id': id,
    'name': name,
    'price_delta': '$delta',
    'is_default': isDefault,
  };

  /// "How spicy" must be answered; "anything extra" need not be.
  List<Map<String, dynamic>> warungMenu() => [
    option(
      group: 'g1', groupName: 'Pedas', min: 1, max: 1,
      id: 'm1', name: 'Kurang pedas',
    ),
    option(
      group: 'g1', groupName: 'Pedas', min: 1, max: 1,
      id: 'm2', name: 'Pedas biasa', isDefault: true,
    ),
    option(
      group: 'g2', groupName: 'Tambah', min: 0,
      id: 'm3', name: 'Telur mata', delta: 2.00,
    ),
    option(
      group: 'g2', groupName: 'Tambah', min: 0,
      id: 'm4', name: 'Ayam goreng', delta: 5.00,
    ),
  ];

  Future<List<String>?> show(
    WidgetTester tester,
    List<Map<String, dynamic>> options, {
    double base = 8.50,
  }) async {
    List<String>? result;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () async {
                  result = await showModalBottomSheet<List<String>>(
                    context: context,
                    isScrollControlled: true,
                    builder: (_) => ModifierSheet(
                      itemName: 'Nasi lemak ayam',
                      basePrice: base,
                      options: options,
                    ),
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return result;
  }

  testWidgets('the rule is written next to the question', (tester) async {
    await show(tester, warungMenu());

    expect(find.text('Pedas'), findsOneWidget);
    expect(find.text('Choose one'), findsOneWidget);
    expect(find.text('Tambah'), findsOneWidget);
    expect(find.text('Optional'), findsOneWidget);
  });

  testWidgets('a default starts chosen, so a regular order is one tap', (
    tester,
  ) async {
    await show(tester, warungMenu());

    // "Pedas biasa" is the shop's own answer to its own question. A
    // default that has to be tapped every time is a default in name.
    final tile = tester.widget<CheckboxListTile>(
      find.widgetWithText(CheckboxListTile, 'Pedas biasa'),
    );
    expect(tile.value, isTrue);
    expect(find.text('Add · RM 8.50'), findsOneWidget);
  });

  testWidgets('choose-one replaces rather than refusing', (tester) async {
    await show(tester, warungMenu());

    await tester.tap(find.text('Kurang pedas'));
    await tester.pumpAndSettle();

    expect(
      tester
          .widget<CheckboxListTile>(
            find.widgetWithText(CheckboxListTile, 'Kurang pedas'),
          )
          .value,
      isTrue,
    );
    // The other one let go on its own. A control that does nothing
    // until you deselect is one nobody understands.
    expect(
      tester
          .widget<CheckboxListTile>(
            find.widgetWithText(CheckboxListTile, 'Pedas biasa'),
          )
          .value,
      isFalse,
    );
  });

  testWidgets('the price on the button follows what was chosen', (
    tester,
  ) async {
    await show(tester, warungMenu());

    await tester.tap(find.text('Telur mata'));
    await tester.pumpAndSettle();
    expect(find.text('Add · RM 10.50'), findsOneWidget);

    await tester.tap(find.text('Ayam goreng'));
    await tester.pumpAndSettle();
    expect(find.text('Add · RM 15.50'), findsOneWidget);
  });

  testWidgets('a required question left open blocks the button and says so', (
    tester,
  ) async {
    // Same menu with no default, so nothing answers "Pedas" for us.
    final menu = warungMenu()
        .map((o) => {...o, 'is_default': false})
        .toList();
    await show(tester, menu);

    expect(find.text('Choose Pedas'), findsOneWidget);
    final button = tester.widget<FilledButton>(find.byType(FilledButton));
    expect(button.onPressed, isNull);

    await tester.tap(find.text('Kurang pedas'));
    await tester.pumpAndSettle();

    expect(find.text('Add · RM 8.50'), findsOneWidget);
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNotNull,
    );
  });

  testWidgets('answering returns the chosen ids, dismissing returns nothing', (
    tester,
  ) async {
    List<String>? out;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () async {
                  out = await showModalBottomSheet<List<String>>(
                    context: context,
                    isScrollControlled: true,
                    builder: (_) => ModifierSheet(
                      itemName: 'Nasi lemak ayam',
                      basePrice: 8.50,
                      options: warungMenu(),
                    ),
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Telur mata'));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('Add · '));
    await tester.pumpAndSettle();

    // `containsAll` takes no type argument — it is
    // `Matcher Function(Iterable<dynamic>)`. Writing containsAll<String>
    // is an analyzer error rather than a runtime one, which is why it
    // took a CI run to find rather than a failing assertion.
    expect(out, containsAll(<String>['m2', 'm3']));

    // And backing out writes nothing at all — the line does not exist
    // yet when the sheet is open, so there is nothing half-built to
    // clean up.
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();
    expect(out, isNull);
  });
}
