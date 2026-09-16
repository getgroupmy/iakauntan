import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/core/theme.dart';
import 'package:iakauntan/src/data/search_registers_repository.dart';
import 'package:iakauntan/src/features/shared/entity_search.dart';

/// Entity Search: which register, before the search.
///
/// The button used to read "Check the SSM register" and knew about one
/// register. A contact is as often an audit firm or a law firm as a
/// company, and the register that knows about each of those is a
/// different one — so it asks first, from a list a platform
/// administrator keeps.
///
/// The distinction that matters on this dialog is `canSearch`, and it
/// is a fact about the REGISTER rather than about how much has been
/// built: SSM answers, MIA's register is behind a bot challenge with no
/// API, and nobody has established what the Bar offers. Picking one
/// that cannot be searched opens its own site, which is what somebody
/// would do anyway. The row has to say which it is going to do, because
/// a dialog that offered three identical-looking choices and then did
/// two different things would be worse than the single button it
/// replaced.
void main() {
  const registers = [
    SearchRegister(
      code: 'ssm',
      name: 'SSM',
      registers: 'Companies and businesses',
      canSearch: true,
      url: 'https://www.ssm-einfo.my/',
      sortOrder: 10,
      isBuiltin: true,
    ),
    SearchRegister(
      code: 'mia',
      name: 'MIA',
      registers: 'Accountants and audit firms',
      url: 'https://mia.org.my/members-firm-search/',
      sortOrder: 20,
      isBuiltin: true,
    ),
    SearchRegister(
      code: 'bar',
      name: 'Malaysian Bar',
      registers: 'Advocates and solicitors',
      url: 'https://www.malaysianbar.org.my/',
      sortOrder: 30,
      isBuiltin: true,
    ),
  ];

  Future<void> open(
    WidgetTester tester, {
    List<SearchRegister> list = registers,
  }) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1280, 900);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          allSearchRegistersProvider.overrideWith((ref) async => list),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showEntitySearch(context),
                child: const Text('Entity Search'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Entity Search'));
    await tester.pumpAndSettle();
  }

  group('reading a register off the wire', () {
    // The dialog is built from objects, so nothing above this exercises
    // `fromJson`. Two surviving mutants said so: a `can_search` read the
    // wrong way round would offer a search for a register that cannot
    // answer one, and a blank address read as an address would send
    // somebody to nowhere.
    test('what it can do comes across as it is', () {
      final searchable = SearchRegister.fromJson(const {
        'code': 'ssm',
        'name': 'SSM',
        'registers': 'Companies and businesses',
        'can_search': true,
        'url': 'https://www.ssm-einfo.my/',
        'sort_order': 10,
        'is_active': true,
        'is_builtin': true,
      });
      expect(searchable.canSearch, isTrue);
      expect(searchable.isBuiltin, isTrue);
      expect(searchable.registers, 'Companies and businesses');
    });

    test('and one that cannot is not read as one that can', () {
      final manual = SearchRegister.fromJson(const {
        'code': 'mia',
        'name': 'MIA',
        'can_search': false,
        'url': 'https://mia.org.my/',
      });
      expect(manual.canSearch, isFalse);
      // The defaults a row may leave out.
      expect(manual.isActive, isTrue);
      expect(manual.isBuiltin, isFalse);
    });

    test('a blank address is no address', () {
      // `''` and "nowhere to send them" are the same thing, and the
      // launcher refuses an empty string with a message that reads as
      // a failure rather than as a register with no page.
      final blank = SearchRegister.fromJson(const {
        'code': 'x',
        'name': 'X',
        'can_search': true,
        'url': '   ',
      });
      expect(blank.url, isNull);
      expect(
        SearchRegister.fromJson(const {'code': 'y', 'name': 'Y'}).url,
        isNull,
      );
    });

    test('a blank description is no description', () {
      expect(
        SearchRegister.fromJson(const {
          'code': 'x',
          'name': 'X',
          'can_search': true,
          'registers': '  ',
        }).registers,
        isNull,
      );
    });
  });

  testWidgets('it asks which register before searching anything', (
    tester,
  ) async {
    await open(tester);

    expect(find.text('Where should I look?'), findsOneWidget);
    expect(find.byKey(const ValueKey('entity-search-ssm')), findsOneWidget);
    expect(find.byKey(const ValueKey('entity-search-mia')), findsOneWidget);
    expect(find.byKey(const ValueKey('entity-search-bar')), findsOneWidget);
  });

  testWidgets('each row says what it registers', (tester) async {
    // The half that tells somebody which to pick. "SSM" alone does not.
    await open(tester);

    expect(find.textContaining('Companies and businesses'), findsOneWidget);
    expect(find.textContaining('Accountants and audit firms'), findsOneWidget);
    expect(find.textContaining('Advocates and solicitors'), findsOneWidget);
  });

  testWidgets('and says which ones only open a page', (tester) async {
    // Two of the three cannot be searched from here. A dialog offering
    // three identical-looking choices that then did two different
    // things would be worse than the one button it replaced.
    await open(tester);

    expect(find.textContaining('opens their own site'), findsNWidgets(2));
  });

  testWidgets('the one that can be searched does not say so', (
    tester,
  ) async {
    // The control for the assertion above: SSM's row carries what it
    // registers and nothing about opening a site.
    await open(tester);

    final ssm = find.descendant(
      of: find.byKey(const ValueKey('entity-search-ssm')),
      matching: find.textContaining('opens their own site'),
    );
    expect(ssm, findsNothing);
  });

  testWidgets('a register switched off is not offered', (tester) async {
    await open(
      tester,
      list: const [
        SearchRegister(code: 'ssm', name: 'SSM', canSearch: true),
        SearchRegister(
          code: 'mia',
          name: 'MIA',
          url: 'https://mia.org.my/',
          isActive: false,
        ),
      ],
    );

    expect(find.byKey(const ValueKey('entity-search-ssm')), findsOneWidget);
    expect(find.byKey(const ValueKey('entity-search-mia')), findsNothing);
  });

  testWidgets('no registers at all says so, and says who fixes it', (
    tester,
  ) async {
    // Not an empty dialog. Somebody pressing Entity Search and getting
    // a blank box would report it as broken rather than as switched
    // off.
    await open(tester, list: const []);

    expect(find.byKey(const ValueKey('entity-search-none')), findsOneWidget);
    expect(find.textContaining('platform administrator'), findsOneWidget);
  });

  testWidgets('cancelling chooses nothing', (tester) async {
    await open(tester);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(find.text('Where should I look?'), findsNothing);
  });
}
