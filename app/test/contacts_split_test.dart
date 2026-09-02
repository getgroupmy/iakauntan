import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/core/providers.dart';
import 'package:iakauntan/src/core/theme.dart';
import 'package:iakauntan/src/data/models.dart';
import 'package:iakauntan/src/features/contacts/contacts_screen.dart';

/// Contacts split into the kinds a business actually keeps.
///
/// One screen behind four doors: All Contacts, and one each for
/// Customer, Supplier and Prospect. Three separate list widgets would be
/// three copies of the same search box drifting apart, so the sidebar
/// entries open the same screen on different tabs — which is only
/// correct if the screen can be told which tab to open on, and if the
/// filter behind each tab means what its label says.
void main() {
  Contact contact(String id, String name, String type) => Contact(
    id: id,
    code: id,
    name: name,
    contactType: type,
  );

  /// What the list was asked for, recorded. The filtering itself is the
  /// server's job; what this pins down is the question the screen asks.
  late List<({String type, String search})> asked;

  Widget harness({String? initialType}) => ProviderScope(
    overrides: [
      repoProvider.overrideWithValue(null),
      canWriteProvider.overrideWithValue(true),
      contactsProvider.overrideWith((ref, args) async {
        asked.add(args);
        return [contact('c1', 'Kumpulan Awan', args.type)];
      }),
    ],
    child: MaterialApp(
      theme: AppTheme.light(),
      // Keyed exactly as the router keys it. Without the key Flutter
      // reuses the State between pumps and the tab never moves, which
      // is the bug this asserts is gone rather than a test detail.
      home: ContactsScreen(
        key: ValueKey(initialType ?? 'all-contacts'),
        initialType: initialType,
      ),
    ),
  );

  setUp(() => asked = []);

  testWidgets('the tabs are the four kinds, with Prospects before All', (
    tester,
  ) async {
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();

    final labels = tester
        .widgetList<SegmentedButton<String>>(find.byType(SegmentedButton<String>))
        .first
        .segments
        .map((s) => s.value)
        .toList();
    expect(labels, ['customer', 'supplier', 'prospect', 'all']);
  });

  testWidgets('All Contacts opens where it always did', (tester) async {
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();
    expect(asked.single.type, 'customer');
  });

  testWidgets('and each door opens the screen on its own tab', (tester) async {
    for (final type in const ['customer', 'supplier', 'prospect']) {
      asked = [];
      await tester.pumpWidget(harness(initialType: type));
      await tester.pumpAndSettle();
      expect(asked.single.type, type, reason: 'the $type door');
    }
  });

  testWidgets('the All tab asks for all of them', (tester) async {
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();

    await tester.tap(find.text('All'));
    await tester.pumpAndSettle();
    expect(asked.last.type, 'all');
  });

  testWidgets('and Prospects asks for prospects', (tester) async {
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Prospects'));
    await tester.pumpAndSettle();
    expect(asked.last.type, 'prospect');
  });
}
