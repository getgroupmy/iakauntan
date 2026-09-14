import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iakauntan/src/data/ssm_repository.dart';
import 'package:iakauntan/src/features/admin/ssm_lookup_admin.dart';
import 'package:iakauntan/src/features/shared/ssm_entity_picker.dart';
import 'package:iakauntan/src/features/shared/ssm_query_hints.dart';

/// Looking a company up in SSM's register.
///
/// The thing worth protecting is narrow. `contacts.registration_no` is
/// what MyInvois validates a party against, so a lookup exists to
/// replace a number somebody keyed with one the registry returned — and
/// `ssm_verified_at` exists to say which of the two a row is carrying.
/// Every assertion below is about not blurring that line: a query that
/// prefers an identifier to a name, a refusal that says what actually
/// happened, and a console that cannot offer to store a credential the
/// rest of this system keeps in the dashboard.
class _FakeSsm implements SsmLookupRepository {
  _FakeSsm({
    this.page,
    this.error,
    this.statusValue = const SsmStatus(
      configured: true,
      cacheRows: 3,
      searches24h: 7,
      loggedInAs: 'ops@example.com',
    ),
  });

  final SsmSearchPage? page;
  final SsmLookupException? error;
  final SsmStatus statusValue;

  final asked = <String>[];
  final saved = <(String, SsmEntity)>[];
  int cacheCleared = 0;

  @override
  Future<SsmSearchPage> search(
    String query, {
    int? typeId,
    int page = 1,
    int perPage = 20,
  }) async {
    asked.add(query);
    if (error != null) throw error!;
    return this.page ??
        const SsmSearchPage(
          items: [],
          total: 0,
          page: 1,
          perPage: 20,
          cached: false,
        );
  }

  @override
  Future<List<SsmEntityType>> entityTypes() async => const [
    SsmEntityType(1, 'Company'),
    SsmEntityType(2, 'Business'),
  ];

  @override
  Future<void> saveToContact(String contactId, SsmEntity entity) async =>
      saved.add((contactId, entity));

  @override
  Future<SsmStatus> status() async => statusValue;

  @override
  Future<String?> testLogin() async => 'ops@example.com';

  @override
  Future<void> clearSession() async {}

  @override
  Future<void> clearCache() async => cacheCleared++;
}

Widget _wrap(Widget child, _FakeSsm fake) => ProviderScope(
  overrides: [ssmLookupProvider.overrideWithValue(fake)],
  child: MaterialApp(home: Scaffold(body: child)),
);

void main() {
  group('what to ask the register', () {
    test('a registration number beats the name it is printed beside', () {
      // A letterhead carries both. The register matches a number
      // exactly and a name approximately, so asking with the number is
      // one search instead of a list to choose from.
      const letterhead =
          'TM TECHNOLOGY SERVICES SDN. BHD.\n'
          '200201003726 (571389-H)\n'
          'Menara TM, Jalan Pantai Baharu, 50672 Kuala Lumpur';

      expect(SsmQueryHints.bestQuery(letterhead), '200201003726');
      expect(SsmQueryHints.candidates(letterhead), [
        '200201003726',
        '571389-H',
        'TM TECHNOLOGY SERVICES SDN BHD',
      ]);
    });

    test('the old form is recognised on its own', () {
      expect(SsmQueryHints.bestQuery('Co. Reg. No: 571389-H'), '571389-H');
      expect(SsmQueryHints.extractOldRegNo('LLP0012345-LGN'), 'LLP0012345-LGN');
      expect(SsmQueryHints.looksLikeRegNo('1339519-K'), isTrue);
      expect(SsmQueryHints.looksLikeRegNo('KABEER HOLDINGS'), isFalse);
    });

    test('a twelve-digit number is not any twelve digits', () {
      // An invoice total, a phone number and an account number all turn
      // up on a bill. The entity code in position five is 01 to 09, so
      // a run of digits that does not have one is not a registration
      // number and must not become the query.
      expect(SsmQueryHints.extractNewRegNo('Account 123456789012'), isNull);
      expect(SsmQueryHints.extractNewRegNo('201901030189'), '201901030189');
    });

    test('the name is cleaned to what the register would call it', () {
      expect(
        SsmQueryHints.cleanName('Kabeer Holdings Sendirian Berhad'),
        'KABEER HOLDINGS SDN BHD',
      );
      // A reader turns a logo into punctuation, and those characters in
      // a query find nothing at all.
      expect(SsmQueryHints.cleanName('~|  ACME  ENTERPRISE  '), 'ACME ENTERPRISE');
    });

    test('nothing worth asking produces no query rather than a bad one', () {
      expect(SsmQueryHints.bestQuery(null), '');
      expect(SsmQueryHints.bestQuery('   '), '');
      // Under the function's own three-character minimum: spending a
      // search on it would be spending it to be told no.
      expect(SsmQueryHints.candidates('AB'), isEmpty);
    });
  });

  group('what comes back', () {
    test('an entity reads both registration numbers', () {
      final e = SsmEntity.fromJson(const {
        'name': 'KABEER HOLDINGS SDN. BHD.',
        'reg_no': '201901030189',
        'reg_no_old': '1339519-K',
        'entity_type': 'Company',
        'entity_type_id': 1,
        'slug': 'kabeer-holdings-sdn-bhd',
      });
      expect(e.registrationDisplay, '201901030189 (1339519-K)');
    });

    test('an entity with no number says so rather than showing nothing', () {
      const e = SsmEntity(name: 'SOMETHING');
      expect(e.registrationDisplay, 'No registration number');
    });

    test('a refusal keeps its code and gains words for a person', () {
      final e = SsmLookupException.from(const {
        'error': {'code': 'SSM_NOT_CONFIGURED', 'message': 'Set the secrets.'},
      }, 503);
      expect(e.notConfigured, isTrue);
      expect(e.userMessage, contains('platform administrator'));

      // Anything the function had real words for keeps them: it knows
      // more about what went wrong than a switch here does.
      final other = SsmLookupException.from(const {
        'error': {'code': 'UPSTREAM', 'message': 'The registry said no.'},
      }, 502);
      expect(other.userMessage, 'The registry said no.');
    });
  });

  group('the picker', () {
    testWidgets('a seeded query is searched without being retyped', (
      tester,
    ) async {
      final fake = _FakeSsm(
        page: const SsmSearchPage(
          items: [
            SsmEntity(
              name: 'KABEER HOLDINGS SDN. BHD.',
              regNo: '201901030189',
              entityType: 'Company',
            ),
          ],
          total: 1,
          page: 1,
          perPage: 20,
          cached: false,
        ),
      );

      SsmEntity? chosen;
      await tester.pumpWidget(
        _wrap(
          Builder(
            builder: (context) => TextButton(
              onPressed: () async => chosen = await showSsmEntityPicker(
                context,
                initialQuery: '201901030189',
              ),
              child: const Text('open'),
            ),
          ),
          fake,
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(fake.asked, ['201901030189']);
      expect(find.text('KABEER HOLDINGS SDN. BHD.'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('ssm-hit-0')));
      await tester.pumpAndSettle();
      // Returned, not written. What a match means differs between the
      // contact editor and the scanned-bill dialog, and the picker
      // deciding it would be deciding it in the wrong place.
      expect(chosen?.regNo, '201901030189');
      expect(fake.saved, isEmpty);
    });

    testWidgets('a lookup nobody has set up is not offered a retry', (
      tester,
    ) async {
      final fake = _FakeSsm(
        error: const SsmLookupException(
          'SSM_NOT_CONFIGURED',
          'Not set up.',
          status: 503,
        ),
      );
      await tester.pumpWidget(
        _wrap(
          Builder(
            builder: (context) => TextButton(
              onPressed: () => showSsmEntityPicker(context, initialQuery: 'ACME'),
              child: const Text('open'),
            ),
          ),
          fake,
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.textContaining('not switched on yet'), findsOneWidget);
      // Trying again would ask the same question and get the same
      // answer. A button that says otherwise is a lie about what is
      // wrong.
      expect(find.text('Try again'), findsNothing);
    });

    testWidgets('a number that matches nothing says something different '
        'from a name that matches nothing', (tester) async {
      final fake = _FakeSsm();
      await tester.pumpWidget(
        _wrap(
          Builder(
            builder: (context) => TextButton(
              onPressed: () =>
                  showSsmEntityPicker(context, initialQuery: '201901030189'),
              child: const Text('open'),
            ),
          ),
          fake,
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.textContaining('No company carries that registration'), findsOneWidget);
    });
  });

  group('the console', () {
    testWidgets('offers nowhere to type a password', (tester) async {
      await tester.pumpWidget(
        _wrap(
          const SsmLookupAdminTab(),
          _FakeSsm(
            statusValue: const SsmStatus(
              configured: false,
              cacheRows: 0,
              searches24h: 0,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // The whole point of the screen's shape. The ssmsearch.com login
      // is an edge-function secret in the Supabase dashboard, like
      // every other secret here, and a box on this page would put a
      // working third-party login in the database.
      expect(find.byType(TextField), findsNothing);
      expect(find.byType(TextFormField), findsNothing);
      expect(find.textContaining('SSMSEARCH_PASSWORD'), findsOneWidget);
    });

    testWidgets('testing a login is offered only once it could work', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(
          const SsmLookupAdminTab(),
          _FakeSsm(
            statusValue: const SsmStatus(
              configured: false,
              cacheRows: 0,
              searches24h: 0,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final button = tester.widget<FilledButton>(
        find.byKey(const ValueKey('ssm-test-login')),
      );
      expect(button.onPressed, isNull);
    });
  });
}
