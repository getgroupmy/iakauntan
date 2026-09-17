import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/core/providers.dart';
import 'package:iakauntan/src/data/custom_fields_repository.dart';
import 'package:iakauntan/src/features/custom_fields/custom_fields_section.dart';

/// The boxes a company added for itself.
///
/// Two things are asserted here, and the first matters more than it
/// looks. A company that has defined nothing must see NOTHING — not an
/// empty heading, not a gap — because eleven editors now call this and
/// most companies will never name a field. A section that drew a header
/// over an empty list would cost every one of them a line of chrome for
/// a feature they do not use.
///
/// The second is that an archived field is not offered, and that the
/// value it holds is not quietly wiped when it goes. The section hands
/// back the WHOLE map and only replaces the keys it drew, so putting a
/// field away leaves what it held on the record.
CustomFieldDef _def({
  required String key,
  required String label,
  String kind = 'text',
  bool required = false,
  bool active = true,
  List<String> options = const [],
  String? target,
}) => CustomFieldDef(
  id: 'id-$key',
  entity: 'contact',
  key: key,
  label: label,
  kind: kind,
  isRequired: required,
  isActive: active,
  showOnList: false,
  sortOrder: 10,
  options: options,
  targetEntity: target,
);

void main() {
  Widget harness({
    required List<CustomFieldDef> defs,
    Map<String, dynamic> values = const {},
    void Function(Map<String, dynamic>)? onChanged,
  }) => ProviderScope(
    overrides: [
      repoProvider.overrideWithValue(null),
      customFieldsProvider('contact').overrideWith((ref) async => defs),
      customFieldLookupProvider((
        target: 'contact',
        search: '',
      )).overrideWith((ref) async => const <LookupOption>[]),
    ],
    child: MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: CustomFieldsSection(
            entity: 'contact',
            values: values,
            onChanged: onChanged ?? (_) {},
          ),
        ),
      ),
    ),
  );

  testWidgets('a company that named no fields sees no section', (t) async {
    await t.pumpWidget(harness(defs: const []));
    await t.pumpAndSettle();
    expect(find.text('Your own fields'), findsNothing);
  });

  testWidgets('a field that was named is drawn, with its help', (t) async {
    await t.pumpWidget(
      harness(defs: [_def(key: 'cost_centre', label: 'Cost centre')]),
    );
    await t.pumpAndSettle();
    expect(find.text('Your own fields'), findsOneWidget);
    expect(find.text('Cost centre'), findsOneWidget);
  });

  testWidgets('one that must be filled in says so on the label', (t) async {
    await t.pumpWidget(
      harness(
        defs: [_def(key: 'cost_centre', label: 'Cost centre', required: true)],
      ),
    );
    await t.pumpAndSettle();
    expect(find.text('Cost centre *'), findsOneWidget);
  });

  testWidgets('an archived field is not offered', (t) async {
    await t.pumpWidget(
      harness(
        defs: [
          _def(key: 'live_one', label: 'Still used'),
          _def(key: 'old_one', label: 'Put away', active: false),
        ],
        values: const {'old_one': 'KL-01'},
      ),
    );
    await t.pumpAndSettle();
    expect(find.text('Still used'), findsOneWidget);
    expect(find.text('Put away'), findsNothing);
  });

  testWidgets('and what an archived field held is not wiped by an edit', (
    t,
  ) async {
    Map<String, dynamic>? sent;
    await t.pumpWidget(
      harness(
        defs: [
          _def(key: 'live_one', label: 'Still used'),
          _def(key: 'old_one', label: 'Put away', active: false),
        ],
        values: const {'old_one': 'KL-01'},
        onChanged: (v) => sent = v,
      ),
    );
    await t.pumpAndSettle();
    await t.enterText(find.byType(TextFormField), 'typed');
    expect(sent, isNotNull);
    expect(sent!['live_one'], 'typed');
    // The one that is no longer offered is still on the record.
    expect(sent!['old_one'], 'KL-01');
  });

  testWidgets('a number is sent as a number, not as its digits', (t) async {
    Map<String, dynamic>? sent;
    await t.pumpWidget(
      harness(
        defs: [_def(key: 'score', label: 'Score', kind: 'number')],
        onChanged: (v) => sent = v,
      ),
    );
    await t.pumpAndSettle();
    await t.enterText(find.byType(TextFormField), '72');
    // The guard refuses "72" where a number belongs, and is right to:
    // "72" and 72 are different answers to "how much".
    expect(sent!['score'], 72);
    expect(sent!['score'], isA<num>());
  });

  testWidgets('a yes-or-no is a switch, and answers with a boolean', (
    t,
  ) async {
    Map<String, dynamic>? sent;
    await t.pumpWidget(
      harness(
        defs: [_def(key: 'on_hold', label: 'On hold', kind: 'boolean')],
        onChanged: (v) => sent = v,
      ),
    );
    await t.pumpAndSettle();
    expect(find.byType(SwitchListTile), findsOneWidget);
    await t.tap(find.byType(SwitchListTile));
    expect(sent!['on_hold'], true);
  });

  test('a definition is read off the row the database returns', () {
    final d = CustomFieldDef.fromJson(const {
      'id': 'abc',
      'entity': 'item',
      'key': 'warranty_provider',
      'label': 'Warranty provider',
      'kind': 'lookup',
      'is_required': true,
      'is_active': true,
      'show_on_list': false,
      'sort_order': 20,
      'target_entity': 'contact',
      'options': null,
    });
    expect(d.key, 'warranty_provider');
    expect(d.isLookup, isTrue);
    expect(d.targetEntity, 'contact');
    expect(d.isRequired, isTrue);
    expect(d.options, isEmpty);
  });
}
