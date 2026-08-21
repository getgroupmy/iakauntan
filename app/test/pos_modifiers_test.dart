import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:iakauntan/src/core/providers.dart';
import 'package:iakauntan/src/core/theme.dart';
import 'package:iakauntan/src/data/models.dart';
import 'package:iakauntan/src/features/items/modifier_groups_dialog.dart';

/// Keeping the questions a plate comes with.
///
/// 0214 built modifiers and the till has asked them since; nothing
/// could ever create one, so the only shop with any was the one a
/// migration seeded. 0250 added the functions and this is the screen.
///
/// What is asserted here is the part a shopkeeper reads rather than the
/// part the server enforces: the rule said back in words, because two
/// number fields are easy to fill in and hard to check, and a retired
/// question staying visible, because there is no way back from a
/// retirement nobody can see.
void main() {
  group('the rule, said out loud', () {
    test('choose one is min one max one', () {
      expect(modifierRule(1, 1), 'choose one');
    });

    test('optional but at most one is not the same thing', () {
      expect(modifierRule(0, 1), 'one at most');
    });

    test('no maximum and nothing required is any you like', () {
      expect(modifierRule(0, null), 'any you like');
    });

    test('a cap with no floor reads as up to', () {
      expect(modifierRule(0, 2), 'up to 2');
    });

    test('and a required range says both ends', () {
      expect(modifierRule(1, 3), '1 to 3');
    });
  });

  group('the questions on a dish', () {
    Map<String, dynamic> group(
      String id,
      String name, {
      bool active = true,
      int min = 0,
      int? max,
    }) => {
      'id': id,
      'code': name.toUpperCase(),
      'name': name,
      'min_select': min,
      'max_select': max,
      'sort_order': 0,
      'is_active': active,
      'option_count': 2,
      'item_count': 1,
    };

    Widget field({
      required List<String> selected,
      required ValueChanged<List<String>> onChanged,
      List<Map<String, dynamic>> groups = const [],
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
        enabledModulesProvider.overrideWith((_) async => {'pos'}),
        posModifierGroupsProvider.overrideWith((_) async => groups),
      ],
      child: MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: ItemModifierField(selected: selected, onChanged: onChanged),
        ),
      ),
    );

    testWidgets('names the questions this dish is sold with', (tester) async {
      await tester.pumpWidget(
        field(
          selected: const ['g1'],
          onChanged: (_) {},
          groups: [group('g1', 'Pedas', min: 1, max: 1), group('g2', 'Tambah')],
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Pedas'), findsOneWidget);
      // Attached is not the same as available: the other question is
      // behind Add, not on the dish.
      expect(find.text('Tambah'), findsNothing);
      expect(find.text('Add'), findsOneWidget);
    });

    testWidgets('deleting a chip detaches that one and nothing else', (
      tester,
    ) async {
      List<String>? handed;
      await tester.pumpWidget(
        field(
          selected: const ['g1', 'g2'],
          onChanged: (v) => handed = v,
          groups: [group('g1', 'Pedas'), group('g2', 'Tambah')],
        ),
      );
      await tester.pumpAndSettle();

      // Through the chip's own callback rather than its delete icon,
      // which is a Material detail and not what this is about.
      tester
          .widget<InputChip>(find.widgetWithText(InputChip, 'Pedas'))
          .onDeleted!();
      await tester.pumpAndSettle();
      expect(handed, ['g2']);
    });

    testWidgets('a question retired since it was attached says so', (
      tester,
    ) async {
      await tester.pumpWidget(
        field(
          selected: const ['g1'],
          onChanged: (_) {},
          groups: [group('g1', 'Pedas', active: false)],
        ),
      );
      await tester.pumpAndSettle();

      // Still on the dish — hiding it would make the field disagree
      // with what the database holds — but marked as asking nothing.
      expect(find.text('Pedas'), findsOneWidget);
      expect(find.byIcon(Icons.block_outlined), findsOneWidget);
      // And it is not offered again, because it is already there.
      expect(find.text('Add'), findsNothing);
    });

    testWidgets('with no questions set up at all, the way in says so', (
      tester,
    ) async {
      await tester.pumpWidget(
        field(selected: const [], onChanged: (_) {}),
      );
      await tester.pumpAndSettle();

      expect(find.text('Set up questions'), findsOneWidget);
    });
  });
}
