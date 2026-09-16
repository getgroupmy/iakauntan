import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show SupabaseClient;

import 'package:iakauntan/src/data/search_registers_repository.dart';
import 'package:iakauntan/src/features/admin/search_registers_admin.dart';

/// The console page that adds a register to Entity Search.
///
/// One rule here is not bookkeeping: a register this application cannot
/// SEARCH must carry an address. Two of the three shipped registers
/// cannot be searched — MIA's is behind a bot challenge with no API,
/// and nobody has established what the Bar offers — so picking one
/// opens its own site instead. A register with neither a search nor an
/// address is a choice that does nothing when somebody picks it, and
/// that is invisible until a user picks it.
class _RecordingRepo extends SearchRegistersRepo {
  _RecordingRepo(super.client);

  final List<Map<String, dynamic>> saved = [];

  @override
  Future<String> save({
    required String code,
    required String name,
    String? registers,
    bool? canSearch,
    String? url,
    int? sortOrder,
    bool? isActive,
  }) async {
    saved.add({
      'code': code,
      'name': name,
      'can_search': canSearch,
      'url': url,
      'sort_order': sortOrder,
    });
    return code;
  }

  @override
  Future<void> remove(String code) async {}
}

void main() {
  // A top-level `final SupabaseClient` is lazy; touching it first
  // inside `testWidgets` starts GoTrue's auto-refresh timer in that
  // test's fake-async zone and fails only the FIRST test.
  setUpAll(() => _unusedClient);

  late _RecordingRepo repo;

  const rows = [
    SearchRegister(
      code: 'ssm',
      name: 'SSM',
      registers: 'Companies and businesses',
      canSearch: true,
      sortOrder: 10,
      isBuiltin: true,
    ),
    SearchRegister(
      code: 'mia',
      name: 'MIA',
      registers: 'Accountants and audit firms',
      url: 'https://mia.org.my/',
      sortOrder: 20,
      isBuiltin: true,
    ),
    SearchRegister(
      code: 'bursa',
      name: 'Bursa',
      url: 'https://www.bursamalaysia.com/',
      sortOrder: 40,
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
          searchRegistersRepoProvider.overrideWithValue(repo),
          allSearchRegistersProvider.overrideWith((ref) async => rows),
        ],
        child: const MaterialApp(
          home: Scaffold(body: SearchRegistersAdminTab()),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> addRegister(
    WidgetTester tester, {
    String code = 'bursa',
    String name = 'Bursa Malaysia',
    String url = '',
    bool canSearch = false,
  }) async {
    await tester.tap(find.byKey(const ValueKey('register-add')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('register-code')), code);
    await tester.enterText(find.byKey(const ValueKey('register-name')), name);
    if (url.isNotEmpty) {
      await tester.enterText(find.byKey(const ValueKey('register-url')), url);
    }
    if (canSearch) {
      await tester.tap(find.byKey(const ValueKey('register-can-search')));
      await tester.pumpAndSettle();
    }
    await tester.tap(find.byKey(const ValueKey('register-save')));
    await tester.pumpAndSettle();
  }

  group('the rule on its own', () {
    test('a register that can neither be asked nor opened is refused', () {
      expect(
        searchRegisterProblem(
          code: 'bursa',
          name: 'Bursa',
          canSearch: false,
          url: '',
          isNew: true,
        ),
        contains('needs an address'),
      );
    });

    test('one that can be searched needs no address', () {
      // The search is the way in, so there is nowhere to send anybody.
      expect(
        searchRegisterProblem(
          code: 'lhdn',
          name: 'LHDN',
          canSearch: true,
          url: '',
          isNew: true,
        ),
        isNull,
      );
    });

    test('and one with an address needs no search', () {
      expect(
        searchRegisterProblem(
          code: 'bursa',
          name: 'Bursa',
          canSearch: false,
          url: 'https://www.bursamalaysia.com/',
          isNew: true,
        ),
        isNull,
      );
    });

    test('an address of spaces is no address', () {
      // `'   '` is what a fingertip leaves in a box somebody tabbed
      // through. Untrimmed it satisfies the rule and produces a
      // register that opens nothing, which is exactly the failure this
      // rule exists to stop.
      expect(
        searchRegisterProblem(
          code: 'bursa',
          name: 'Bursa',
          canSearch: false,
          url: '   ',
          isNew: true,
        ),
        contains('needs an address'),
      );
    });

    test('a code is still a code', () {
      expect(
        searchRegisterProblem(
          code: 'Bursa Malaysia',
          name: 'Bursa',
          canSearch: true,
          url: '',
          isNew: true,
        ),
        contains('lower-case'),
      );
    });

    test('an existing register is not asked for its code again', () {
      expect(
        searchRegisterProblem(
          code: '',
          name: 'Renamed',
          canSearch: true,
          url: '',
          isNew: false,
        ),
        isNull,
      );
    });
  });

  group('the page', () {
    testWidgets('lists them and says which are searched from here', (
      tester,
    ) async {
      await open(tester);

      expect(find.textContaining('searched from here'), findsOneWidget);
      expect(find.textContaining('opens their own site'), findsNWidgets(2));
      // A switched-off register has to be visible to be switched on.
      expect(find.text('Bursa'), findsOneWidget);
      expect(find.text('Off'), findsOneWidget);
    });

    testWidgets('says that switching the flag on does not make a search', (
      tester,
    ) async {
      // The thing an operator would otherwise assume.
      await open(tester);

      final note = tester.widget<Text>(
        find.byKey(const ValueKey('register-note')),
      );
      expect(note.data, contains('does not make a'));
      expect(note.data, contains('opens its site'));
    });

    testWidgets('a register with nowhere to go is refused before it is sent', (
      tester,
    ) async {
      await open(tester);
      await addRegister(tester);

      expect(repo.saved, isEmpty);
      expect(find.textContaining('needs an address'), findsOneWidget);
    });

    testWidgets('with an address it saves', (tester) async {
      // The control. Without it a page refusing everything would pass
      // the assertion above and no register could be added.
      await open(tester);
      await addRegister(tester, url: 'https://www.bursamalaysia.com/');

      expect(repo.saved.single['code'], 'bursa');
      expect(repo.saved.single['url'], 'https://www.bursamalaysia.com/');
      expect(repo.saved.single['can_search'], isFalse);
    });

    testWidgets('and one that can be searched saves without one', (
      tester,
    ) async {
      await open(tester);
      await addRegister(tester, code: 'lhdn', name: 'LHDN', canSearch: true);

      expect(repo.saved.single['can_search'], isTrue);
    });

    testWidgets('a built-in register offers no Remove', (tester) async {
      await open(tester);
      await tester.tap(find.text('SSM'));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('register-delete')), findsNothing);
      final code = tester.widget<TextField>(
        find.byKey(const ValueKey('register-code')),
      );
      expect(code.enabled, isFalse);
    });

    testWidgets('one that was added does', (tester) async {
      await open(tester);
      await tester.tap(find.text('Bursa'));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('register-delete')), findsOneWidget);
    });
  });
}

/// A client no test calls through; every method reaching it is
/// overridden above.
final _unusedClient = SupabaseClient('https://example.invalid', 'not-a-key');
