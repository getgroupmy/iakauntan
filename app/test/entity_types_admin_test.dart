import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show SupabaseClient;

import 'package:iakauntan/src/core/theme.dart';
import 'package:iakauntan/src/data/entity_types_repository.dart';
import 'package:iakauntan/src/features/admin/entity_types_admin.dart';

/// The console page that adds a kind of business.
///
/// `0605` turned `app.entity_type` from an enum into a table so an
/// eleventh kind stopped needing a migration. Almost everything on this
/// page is a label and a sort order — cosmetic, and wrong is visible.
///
/// One field is not. `is_public_company` is what MBRS reads to decide
/// whether a company files its accounts as a public company; until
/// `0605` that was `o.entity_type = 'bhd'`, a string comparison against
/// one member of a list nobody could add to. A kind added here has to
/// answer it, and the answer starts at NO — so the way to get it wrong
/// is to claim a private company is public, which somebody notices,
/// rather than to forget and have MBRS quietly file the wrong return.
class _RecordingRepo extends EntityTypesRepo {
  _RecordingRepo(super.client);

  final List<Map<String, dynamic>> saved = [];
  final List<String> removed = [];

  @override
  Future<String> save({
    required String code,
    required String label,
    String? labelMy,
    int? sortOrder,
    bool? isActive,
    bool? isPublicCompany,
    bool? forContacts,
    bool? forOrganizations,
  }) async {
    saved.add({
      'code': code,
      'label': label,
      'sort_order': sortOrder,
      'is_public_company': isPublicCompany,
      'is_active': isActive,
    });
    return code;
  }

  @override
  Future<void> remove(String code) async => removed.add(code);
}

void main() {
  // See `landing_sort_order_test.dart`: a top-level `final
  // SupabaseClient` is lazy, and touching it first inside `testWidgets`
  // starts GoTrue's auto-refresh timer inside that test's fake-async
  // zone — which fails only the FIRST test, for a reason unrelated to
  // anything it asserts.
  setUpAll(() => _unusedClient);

  late _RecordingRepo repo;

  const builtIn = [
    EntityType(
      code: 'sdn_bhd',
      label: 'Sdn Bhd',
      sortOrder: 10,
      isBuiltin: true,
    ),
    EntityType(
      code: 'bhd',
      label: 'Berhad',
      sortOrder: 20,
      isPublicCompany: true,
      isBuiltin: true,
    ),
    EntityType(
      code: 'co_operative',
      label: 'Co-operative',
      sortOrder: 45,
      isActive: false,
    ),
  ];

  Future<void> open(WidgetTester tester) async {
    repo = _RecordingRepo(_unusedClient);
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1280, 1600);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          entityTypesRepoProvider.overrideWithValue(repo),
          allEntityTypesProvider.overrideWith((ref) async => builtIn),
        ],
        child: const MaterialApp(
          home: Scaffold(body: EntityTypesAdminTab()),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  group('the rule on its own', () {
    test('a new kind needs a code and a name', () {
      expect(
        entityTypeProblem(code: '', label: 'Trust', isNew: true),
        isNotNull,
      );
      expect(
        entityTypeProblem(code: 'trust', label: '  ', isNew: true),
        isNotNull,
      );
      expect(
        entityTypeProblem(code: 'trust', label: 'Trust', isNew: true),
        isNull,
      );
    });

    test('a code is not a label', () {
      // The code is written onto every contact filed as this kind, so
      // it is checked here as well as in the function: a refusal that
      // arrives as a constraint name is one nobody can act on.
      expect(
        entityTypeProblem(code: 'Co Operative', label: 'X', isNew: true),
        contains('lower-case'),
      );
      expect(
        entityTypeProblem(code: 'CoOperative', label: 'X', isNew: true),
        isNotNull,
      );
      expect(
        entityTypeProblem(code: '9lives', label: 'X', isNew: true),
        isNotNull,
      );
    });

    test('an existing kind is not asked for its code again', () {
      // It cannot be changed, so it must not be able to fail.
      expect(
        entityTypeProblem(code: '', label: 'Renamed', isNew: false),
        isNull,
      );
    });
  });

  group('the page', () {
    testWidgets('lists what is on the table, off ones included', (
      tester,
    ) async {
      await open(tester);

      expect(find.text('Sdn Bhd'), findsOneWidget);
      // An operator has to see a switched-off kind in order to switch
      // it back on.
      expect(find.text('Co-operative'), findsOneWidget);
      // `StatusChip` draws through `Fmt.label`, which title-cases.
      expect(find.text('Off'), findsOneWidget);
      expect(find.text('Public company'), findsOneWidget);
    });

    testWidgets('says the deadlines are not decided here', (tester) async {
      // The question anybody adding a kind will ask, answered on the
      // page rather than in a migration header nobody reads.
      await open(tester);

      final note = tester.widget<Text>(
        find.byKey(const ValueKey('entity-type-note')),
      );
      // The claim, not merely the word. An earlier version of this
      // asserted `contains('deadline')`, which a note saying the
      // opposite would also satisfy — the sentence below it mentions
      // deadlines too, and a surviving mutant proved the assertion
      // could not tell the two apart.
      expect(note.data, contains('deadlines are NOT decided here'));
      expect(note.data, contains('reads that one'));
      expect(note.data, contains('MBRS'));
    });

    testWidgets('a new kind is not a public company unless it says so', (
      tester,
    ) async {
      // The default is the safe direction.
      await open(tester);
      await tester.tap(find.byKey(const ValueKey('entity-type-add')));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const ValueKey('entity-type-code')),
        'trust',
      );
      await tester.enterText(
        find.byKey(const ValueKey('entity-type-label')),
        'Trust',
      );
      await tester.tap(find.byKey(const ValueKey('entity-type-save')));
      await tester.pumpAndSettle();

      expect(repo.saved.single['code'], 'trust');
      expect(repo.saved.single['is_public_company'], isFalse);
    });

    testWidgets('and is one when it does', (tester) async {
      // The control. Without it, a page that always sent false would
      // pass the assertion above and no public company could be added.
      await open(tester);
      await tester.tap(find.byKey(const ValueKey('entity-type-add')));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const ValueKey('entity-type-code')),
        'berhad_listed',
      );
      await tester.enterText(
        find.byKey(const ValueKey('entity-type-label')),
        'Berhad (listed)',
      );
      await tester.tap(find.byKey(const ValueKey('entity-type-public')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('entity-type-save')));
      await tester.pumpAndSettle();

      expect(repo.saved.single['is_public_company'], isTrue);
    });

    testWidgets('a code that is not a code is refused before it is sent', (
      tester,
    ) async {
      await open(tester);
      await tester.tap(find.byKey(const ValueKey('entity-type-add')));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const ValueKey('entity-type-code')),
        'Co Operative',
      );
      await tester.enterText(
        find.byKey(const ValueKey('entity-type-label')),
        'Co-operative',
      );
      await tester.tap(find.byKey(const ValueKey('entity-type-save')));
      await tester.pumpAndSettle();

      expect(repo.saved, isEmpty);
      expect(find.textContaining('lower-case'), findsOneWidget);
    });

    testWidgets('an unreadable order is refused, not quietly ignored', (
      tester,
    ) async {
      // The landing console's lesson, applied before it could be made
      // again: `int.tryParse` returning null means "leave it" to the
      // function, so an unreadable box saved nothing and said "Saved".
      await open(tester);
      await tester.tap(find.byKey(const ValueKey('entity-type-add')));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const ValueKey('entity-type-code')),
        'trust',
      );
      await tester.enterText(
        find.byKey(const ValueKey('entity-type-label')),
        'Trust',
      );
      await tester.enterText(
        find.byKey(const ValueKey('entity-type-order')),
        '1O',
      );
      await tester.tap(find.byKey(const ValueKey('entity-type-save')));
      await tester.pumpAndSettle();

      expect(repo.saved, isEmpty);
      expect(find.textContaining('whole number'), findsOneWidget);
    });

    testWidgets('a built-in kind offers no Remove', (tester) async {
      // `organizations.entity_type` is still the enum and still holds
      // these values, so the function refuses; the button is not there
      // to be pressed either.
      await open(tester);
      await tester.tap(find.text('Sdn Bhd'));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('entity-type-delete')), findsNothing);
      // And its code cannot be retyped, because it is already written
      // onto every contact filed as it.
      final code = tester.widget<TextField>(
        find.byKey(const ValueKey('entity-type-code')),
      );
      expect(code.enabled, isFalse);
    });

    testWidgets('one that was added does', (tester) async {
      await open(tester);
      await tester.tap(find.text('Co-operative'));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('entity-type-delete')), findsOneWidget);
    });
  });
}

/// A client no test calls through; every method reaching it is
/// overridden above.
final _unusedClient = SupabaseClient('https://example.invalid', 'not-a-key');
