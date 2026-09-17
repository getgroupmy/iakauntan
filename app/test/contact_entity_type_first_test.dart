import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/core/providers.dart';
import 'package:iakauntan/src/core/theme.dart';
import 'package:iakauntan/src/data/entity_types_repository.dart';
import 'package:iakauntan/src/data/models.dart';
import 'package:iakauntan/src/data/repository.dart';
import 'package:iakauntan/src/features/contacts/contact_editor.dart';

/// What kind of business, asked BEFORE the name.
///
/// The field used to sit below the name with `sdn_bhd` already in it,
/// which made the commonest kind the one nobody was ever asked about: a
/// sole proprietor or an enterprise typed in quickly was filed as a
/// private limited company, and nothing on the screen had said so. The
/// only trace was a field somebody would have had to scroll down and
/// look at.
///
/// So the order is the fix and the DEFAULT is the other half of it.
/// Moving the field up while leaving it pre-filled would change
/// nothing: somebody would still not choose. The form now opens with no
/// answer and the name box does not appear until there is one.
///
/// `0605` also moved the list off the `app.entity_type` enum and onto a
/// table a platform administrator can add to, which is why these tests
/// supply the kinds rather than expecting the ten that used to be
/// hard-coded in this file's source.
void main() {
  const kinds = [
    EntityType(code: 'sdn_bhd', label: 'Sdn Bhd', sortOrder: 10),
    EntityType(code: 'enterprise', label: 'Enterprise', sortOrder: 40),
    // One a platform administrator added. The form must draw it exactly
    // like the built-in ones; nothing here knows the difference.
    EntityType(code: 'co_operative', label: 'Co-operative', sortOrder: 45),
  ];

  late _FakeRepo repo;

  Widget wrap({String? contactId, List<EntityType> list = kinds}) =>
      ProviderScope(
        overrides: [
          repoProvider.overrideWithValue(repo),
          currentOrgProvider.overrideWith(
            (ref) async =>
                Organization(id: 'o1', name: 'Kedai Kita', slug: 'kedai'),
          ),
          memberRoleProvider.overrideWith((ref) async => 'owner'),
          allEntityTypesProvider.overrideWith((ref) async => list),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(body: ContactEditor(contactId: contactId)),
        ),
      );

  Future<void> open(
    WidgetTester tester, {
    String? contactId,
    List<EntityType> list = kinds,
  }) async {
    tester.view.devicePixelRatio = 1.0;
    // Tall, because the assertion is about which fields EXIST rather
    // than which are on screen, and a short viewport would make a field
    // that is merely below the fold read as absent.
    tester.view.physicalSize = const Size(1400, 2400);
    addTearDown(tester.view.reset);
    repo = _FakeRepo();
    await tester.pumpWidget(wrap(contactId: contactId, list: list));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
  }

  Future<void> choose(WidgetTester tester, String label) async {
    await tester.tap(find.byKey(const ValueKey('contact-entity-type')));
    await tester.pumpAndSettle();
    await tester.tap(find.text(label).last);
    await tester.pumpAndSettle();
  }

  testWidgets('a new contact is asked the kind first, and nothing else yet', (
    tester,
  ) async {
    await open(tester);

    expect(find.byKey(const ValueKey('contact-entity-type')), findsOneWidget);
    expect(find.byKey(const ValueKey('contact-entity-first')), findsOneWidget);
    // The name is the field this is in front of.
    expect(find.widgetWithText(TextFormField, 'Name *'), findsNothing);
  });

  testWidgets('and the rest of the form follows once it is answered', (
    tester,
  ) async {
    await open(tester);
    await choose(tester, 'Enterprise');

    expect(find.widgetWithText(TextFormField, 'Name *'), findsOneWidget);
    expect(find.byKey(const ValueKey('contact-entity-first')), findsNothing);
  });

  testWidgets('a kind the console added is offered like any other', (
    tester,
  ) async {
    // The whole point of 0605. Nothing in this form knows which kinds
    // shipped with the product.
    await open(tester);
    await choose(tester, 'Co-operative');

    expect(find.widgetWithText(TextFormField, 'Name *'), findsOneWidget);
  });

  testWidgets('what was chosen is what is saved', (tester) async {
    // Choosing and saving are different things, and a form that drew
    // the choice without sending it would pass every assertion above.
    await open(tester);
    await choose(tester, 'Co-operative');
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Name *'),
      'Koperasi Maju Berhad',
    );
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));

    expect(repo.saved?.entityType, 'co_operative');
    expect(repo.saved?.name, 'Koperasi Maju Berhad');
  });

  testWidgets('an existing contact opens whole, already answered', (
    tester,
  ) async {
    // Somebody correcting a phone number must not be made to re-answer
    // what kind of business it is.
    await open(tester, contactId: 'c1');

    expect(find.byKey(const ValueKey('contact-entity-first')), findsNothing);
    expect(find.widgetWithText(TextFormField, 'Name *'), findsOneWidget);
  });

  testWidgets('a kind since switched off is kept, not silently dropped', (
    tester,
  ) async {
    // The contact is filed as `enterprise` and an administrator has
    // since switched it off. Showing no answer would look like nobody
    // had ever chosen one, and saving from that screen would change the
    // contact's kind without anybody asking for it.
    await open(
      tester,
      contactId: 'c1',
      list: const [EntityType(code: 'sdn_bhd', label: 'Sdn Bhd')],
    );

    expect(find.textContaining('no longer offered'), findsOneWidget);
    expect(find.widgetWithText(TextFormField, 'Name *'), findsOneWidget);
  });

  testWidgets('a list that has not arrived is not an empty list', (
    tester,
  ) async {
    // An empty dropdown reads as "there are no kinds", and the answer
    // is the gate for the whole form. It says it is loading instead.
    await open(tester, list: const []);

    expect(find.textContaining('Loading the list'), findsOneWidget);
    expect(find.widgetWithText(TextFormField, 'Name *'), findsNothing);
  });
}

class _FakeRepo implements Repo {
  Contact? saved;

  @override
  Future<Contact> contact(String id) async => Contact(
    id: 'c1',
    code: 'C-0001',
    name: 'Rantaian Maju Sdn Bhd',
    contactType: 'customer',
    entityType: 'enterprise',
  );

  @override
  Future<Contact> saveContact(Contact contact, {String? id}) async {
    saved = contact;
    return contact;
  }

  /// See `contact_credit_limit_test.dart` for why this is answered here
  /// rather than by overriding the extension method that calls it: a
  /// Dart extension method binds to the static type, so a `@override`
  /// on this fake would not be one.
  @override
  Future<dynamic> callRpc(String fn, {Map<String, dynamic>? params}) async =>
      null;

  @override
  Future<List<Map<String, dynamic>>> groupCompanies() async => const [];

  @override
  Future<List<Map<String, dynamic>>> priceLevels() async => const [];

  @override
  Future<List<Map<String, dynamic>>> states() async => const [];

  @override
  Future<List<Account>> accounts({bool postableOnly = false}) async => const [];

  @override
  Future<String> nextContactCode(String contactType) async => 'C-0002';

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
    'the contact editor called Repo.${invocation.memberName}, '
    'which this fake does not answer',
  );
}
