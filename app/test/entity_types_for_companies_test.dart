import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/core/providers.dart';
import 'package:iakauntan/src/core/theme.dart';
import 'package:iakauntan/src/data/entity_types_repository.dart';
import 'package:iakauntan/src/data/models.dart';
import 'package:iakauntan/src/features/onboarding/onboarding_copy.dart';
import 'package:iakauntan/src/features/settings/company_card.dart';

/// A company's kind of business, after `0607` put it on a table.
///
/// `entity_types_admin_test.dart` covers the console that adds one.
/// This is the other side: the two screens that DRAW the list, and the
/// one line in each of them that a table can break where an enum could
/// not.
///
/// The line that mattered most is gone rather than asserted. It was:
///
///     _entityType = _entityTypes.containsKey(o.entityType)
///         ? o.entityType : 'other';
///
/// and it was correct for as long as the hardcoded map WAS the enum.
/// Against a table an administrator adds to, it silently refiles a
/// company on a new kind as `other` the next time anybody opens the
/// dialog and presses Save. The company below is filed as `koperasi`,
/// which is not one of the ten, and the assertion is that it still is.
void main() {
  const offered = [
    EntityType(code: 'sdn_bhd', label: 'Sdn Bhd', sortOrder: 10),
    EntityType(
      code: 'bhd',
      label: 'Berhad',
      sortOrder: 20,
      isPublicCompany: true,
    ),
    EntityType(code: 'llp', label: 'LLP (PLT)', sortOrder: 30),
    // Added in the console. Not a member of `app.entity_type` and
    // never was.
    EntityType(code: 'koperasi', label: 'Koperasi', sortOrder: 65),
    // Offered to contacts and not to companies, which is what
    // `for_organizations` is for.
    EntityType(
      code: 'individual',
      label: 'Individual',
      sortOrder: 90,
      forOrganizations: false,
      isIndividual: true,
    ),
    // Switched off. Still held by anything already filed as it.
    EntityType(
      code: 'lama',
      label: 'An older kind',
      sortOrder: 95,
      isActive: false,
    ),
  ];

  Organization org(String kind) => Organization(
    id: 'o',
    name: 'Koperasi Maju Jaya',
    slug: 'maju',
    entityType: kind,
    baseCurrency: 'MYR',
  );

  Widget harness(String kind, {List<EntityType>? types}) => ProviderScope(
    overrides: [
      canAdminProvider.overrideWithValue(true),
      hasPostingsProvider.overrideWith((_) async => false),
      allEntityTypesProvider.overrideWith((ref) async => types ?? offered),
    ],
    child: MaterialApp(
      theme: AppTheme.light(),
      home: Scaffold(body: CompanyCard(org: org(kind))),
    ),
  );

  Future<void> wide(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  group('what to call a kind', () {
    test('the table wins, where the table has loaded', () {
      // `Fmt.label` would make this "Llp plt".
      expect(entityTypeLabel(offered, 'llp'), 'LLP (PLT)');
    });

    test('and the code is formatted where it has not', () {
      expect(entityTypeLabel(null, 'sole_proprietor'), 'Sole Proprietor');
    });

    test('a kind that is not on the list is shown as what is stored', () {
      // Not invented, not "Other", not blank. The code is what the row
      // actually holds and hiding it would hide the problem.
      expect(entityTypeLabel(offered, 'hantu'), 'hantu');
    });

    test('and nothing at all says so', () {
      expect(entityTypeLabel(offered, '   '), 'Not set');
    });
  });

  group('the company card', () {
    testWidgets('shows the label the console gave the kind', (tester) async {
      await wide(tester);
      await tester.pumpWidget(harness('koperasi'));
      await tester.pumpAndSettle();

      expect(find.text('Koperasi'), findsOneWidget);
    });

    testWidgets('and a kind added in the console survives being edited', (
      tester,
    ) async {
      await wide(tester);
      await tester.pumpWidget(harness('koperasi'));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('edit-company')));
      await tester.pumpAndSettle();

      // The dropdown's own value, read off the widget rather than off
      // the screen: the dialog is what would have rewritten it.
      final field = tester.widget<DropdownButtonFormField<String>>(
        find.byType(DropdownButtonFormField<String>).first,
      );
      expect(field.initialValue, 'koperasi');
    });

    testWidgets('a kind switched off is still offered to the company on it', (
      tester,
    ) async {
      await wide(tester);
      await tester.pumpWidget(harness('lama'));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('edit-company')));
      await tester.pumpAndSettle();

      // A dropdown whose `value` is not among its `items` throws, and
      // the company that would throw is exactly the one somebody opened
      // this dialog to correct.
      expect(tester.takeException(), isNull);
      final field = tester.widget<DropdownButtonFormField<String>>(
        find.byType(DropdownButtonFormField<String>).first,
      );
      expect(field.initialValue, 'lama');
    });

    testWidgets('and the dialog opens before the list has arrived', (
      tester,
    ) async {
      await wide(tester);
      await tester.pumpWidget(harness('sdn_bhd', types: const []));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('edit-company')));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
    });
  });

  group('what registration is offered', () {
    test('the constant, where the server sent nothing', () {
      // A deployment whose `signup_reference()` predates 0607 answers
      // without the list. A sign-up form that cannot offer an entity
      // type is a sign-up form nobody can finish.
      expect(signupEntityTypes(null), entityTypes);
      expect(signupEntityTypes(const []), entityTypes);
    });

    test('and what it sent, where it sent some', () {
      final got = signupEntityTypes(const [
        {'code': 'sdn_bhd', 'label': 'Sdn Bhd'},
        {'code': 'koperasi', 'label': 'Koperasi'},
      ]);
      expect(got.keys.toList(), ['sdn_bhd', 'koperasi']);
      expect(got['koperasi'], 'Koperasi');
    });

    test('in the order it sent them, which is the table sort order', () {
      final got = signupEntityTypes(const [
        {'code': 'zzz', 'label': 'Last alphabetically, first by order'},
        {'code': 'aaa', 'label': 'First alphabetically'},
      ]);
      expect(got.keys.first, 'zzz');
    });

    test('a row with no code is dropped rather than drawn blank', () {
      // A dropdown item whose value is the empty string is one somebody
      // can select, and it would be saved.
      final got = signupEntityTypes(const [
        {'code': '', 'label': 'Nothing'},
        {'code': 'sdn_bhd', 'label': 'Sdn Bhd'},
      ]);
      expect(got.keys.toList(), ['sdn_bhd']);
    });

    test('and a row with no label falls back to its code', () {
      final got = signupEntityTypes(const [
        {'code': 'koperasi'},
      ]);
      expect(got['koperasi'], 'koperasi');
    });

    test('a list of nothing but blank codes is the constant', () {
      // Not an empty dropdown. This is the same failure as the server
      // sending nothing, arriving in a different shape.
      expect(signupEntityTypes(const [
        {'code': '  '},
      ]), entityTypes);
    });
  });
}
