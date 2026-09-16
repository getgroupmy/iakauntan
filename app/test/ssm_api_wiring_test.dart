import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart'
    show FunctionResponse, SupabaseClient;

import 'package:iakauntan/src/services/ssm_search_service.dart';

/// The thirteen endpoints, followed all the way through.
///
/// "Wired end to end" is a claim about three files in two languages:
/// a Dart method sends an action, `supabase/functions/ssm-api/index.ts`
/// has a case for it, and that case calls the matching method on
/// `SsmSearchClient`. Nothing in either language can see the whole
/// chain — `flutter analyze` does not read TypeScript and `deno check`
/// does not read Dart — so a renamed action is a screen that fails at
/// runtime with "unknown action", and every test on either side goes on
/// passing.
///
/// This reads the two TypeScript files as text and checks the links.
/// Crude, and the crudeness is the point: it cannot be satisfied by
/// mocking, and it fails the moment either side is renamed alone.
///
/// The other half — that a Dart method sends the action and the
/// parameters it claims to — is driven through the real service against
/// a recording invoker, because a list of names agreeing with another
/// list of names proves nothing about what is actually sent.
void main() {
  final root = Directory.current.path.endsWith('/app')
      ? Directory(Directory.current.parent.path)
      : Directory.current;
  final edge = File(
    '${root.path}/supabase/functions/ssm-api/index.ts',
  ).readAsStringSync();
  final client = File(
    '${root.path}/supabase/functions/_shared/ssm-search-client.ts',
  ).readAsStringSync();

  group('the two sides name the same actions', () {
    test('the edge function was found at all', () {
      // Without this the reads above could return an empty string and
      // every assertion below would pass against nothing. It has
      // happened in this repository before.
      expect(edge.length, greaterThan(2000));
      expect(client.length, greaterThan(2000));
      expect(edge, contains('serveFunction("ssm-api"'));
    });

    test('every action the app sends is one the function answers to', () {
      for (final action in SsmSearchService.actions) {
        expect(
          edge,
          contains(RegExp('^  $action: \\{', multiLine: true)),
          reason: '$action is sent by the app and has no case in ssm-api',
        );
      }
    });

    test('and the function answers to nothing the app cannot send', () {
      // The other direction. An action added to the function and not to
      // the app is an endpoint nobody can reach, which is the quieter
      // half of the same mistake.
      final declared = RegExp(r'^  ([a-zA-Z]+): \{$', multiLine: true)
          .allMatches(edge)
          .map((m) => m.group(1)!)
          .toSet();
      expect(declared, isNotEmpty);
      expect(declared.difference(SsmSearchService.actions.toSet()), isEmpty);
    });

    test('all thirteen endpoints plus the three the flow uses', () {
      // The count is the claim. Sixteen: thirteen documented endpoints
      // and search / searchAll / profile, which the contact lookup
      // actually calls.
      expect(SsmSearchService.actions.length, 16);
    });

    test('every endpoint method on the client is reached by an action', () {
      // The third link. A method on `SsmSearchClient` that no action
      // calls is an endpoint paid for and unreachable.
      for (final method in const [
        'searchEntity',
        'businessProfile',
        'companyProfile',
        'directorsOfficers',
        'shareCapital',
        'shareholders',
        'registeredAddressChanges',
        'companySecretary',
        'companyCharges',
        'auditFirmProfile',
        'llpCurrentProfile',
        'imageView',
        'image',
      ]) {
        expect(
          client,
          contains(RegExp('^  $method\\(body:', multiLine: true)),
          reason: '$method is not declared on SsmSearchClient',
        );
        expect(
          edge,
          contains('client.$method('),
          reason: '$method is on the client and no action calls it',
        );
      }
    });
  });

  group('what the app actually sends', () {
    late String sentAction;
    late Map<String, dynamic> sentParams;
    late Map<String, dynamic> sentBody;

    SsmSearchService serviceReturning(
      Object? data, {
      String? orgId = 'org-1',
    }) =>
        SsmSearchService(
          // Never touched: every call goes through the invoker below.
          // The parameter is not nullable, and a service built round a
          // concrete client is why the seam exists at all.
          _unusedClient,
          orgId: orgId,
          invoker: (name, body) async {
            sentBody = body;
            sentAction = body['action'] as String;
            sentParams = (body['params'] as Map).cast<String, dynamic>();
            return FunctionResponse(
              status: 200,
              data: {'ok': true, 'data': data, 'cached': false},
            );
          },
        );

    test('a search names the action and carries the query', () async {
      final svc = serviceReturning({
        'hits': [
          {
            'name': 'MAJU SDN. BHD.',
            'newRegNo': '199301012345',
            'oldRegNo': '123456-X',
            'entityType': 'company',
          },
        ],
        'currentPage': '1',
        'nextPage': '2',
      });
      final page = await svc.search(name: ' MAJU ', entityType: 'company');

      expect(sentAction, 'search');
      // Trimmed on the way out: a trailing space is a different cache
      // key for the same search, and a charged call for an answer
      // already bought.
      expect(sentParams['name'], 'MAJU');
      expect(sentParams['entityType'], 'company');
      expect(sentParams['page'], '1');
      expect(page.hits.single.newRegNo, '199301012345');
      expect(page.hasMore, isTrue);
    });

    test('the four fields a result saves survive the trip', () async {
      // The whole point of the search: name, new registration number,
      // old registration number and entity type, exactly as the
      // existing flow saves them.
      final svc = serviceReturning({
        'hits': [
          {
            'name': 'KABEER HOLDINGS SDN. BHD.',
            'newRegNo': '201901030189',
            'oldRegNo': '1339519-K',
            'entityType': 'company',
          },
        ],
      });
      final hit = (await svc.search(name: 'KABEER')).hits.single;

      expect(hit.name, 'KABEER HOLDINGS SDN. BHD.');
      expect(hit.newRegNo, '201901030189');
      expect(hit.oldRegNo, '1339519-K');
      expect(hit.entityType, 'company');
      expect(hit.display, contains('201901030189'));
      expect(hit.display, contains('(1339519-K)'));
    });

    test('the company is named as org_id, not orgId', () async {
      // The edge function reads `org_id`, like every other function in
      // this repository. A body under the other spelling is refused
      // with "org_id is required" on every single call.
      final svc = serviceReturning({'hits': const []});
      await svc.search(name: 'ANY');

      expect(sentBody['org_id'], 'org-1');
      expect(sentBody.containsKey('orgId'), isFalse);
    });

    test('and is left out entirely when there is none', () async {
      final svc = serviceReturning({'hits': const []}, orgId: null);
      await svc.search(name: 'ANY');

      expect(sentBody.containsKey('org_id'), isFalse);
    });

    test('each of the thirteen sends its own action and key', () async {
      // One table, because the mistake this catches is a copy-and-paste
      // one: thirteen near-identical methods, and the twelfth sending
      // the eleventh's action would look right in every review.
      final cases = <String, Future<void> Function(SsmSearchService)>{
        'businessProfile': (s) => s.businessProfile('SP0503123-L'),
        'companyProfile': (s) => s.companyProfile('199301012345'),
        'directorsOfficers': (s) => s.directorsOfficers('199301012345'),
        'shareCapital': (s) => s.shareCapital('199301012345'),
        'shareholders': (s) => s.shareholders('199301012345'),
        'registeredAddressChanges': (s) =>
            s.registeredAddressChanges('199301012345'),
        'companySecretary': (s) => s.companySecretary('199301012345'),
        'companyCharges': (s) => s.companyCharges('199301012345'),
      };
      for (final entry in cases.entries) {
        final svc = serviceReturning(<String, dynamic>{});
        await entry.value(svc);
        expect(sentAction, entry.key);
        expect(sentParams['regNo'], isNotNull, reason: entry.key);
      }
    });

    test('an audit firm is asked for by firm number', () async {
      // Not `regNo`. `get-auditfirm-particular` takes `adtFirmNo`, and
      // a body under the wrong key is a charged call that finds
      // nothing.
      final svc = serviceReturning(<String, dynamic>{});
      await svc.auditFirmProfile('AF0301');

      expect(sentAction, 'auditFirmProfile');
      expect(sentParams['adtFirmNo'], 'AF0301');
      expect(sentParams.containsKey('regNo'), isFalse);
    });

    test('an LLP is asked for by its OLD number', () async {
      // `get-llp-current-profile` takes `entityNoOldFormat`. The new
      // twelve-digit number finds nothing there, which is the one place
      // in this API where the older number is the right one.
      final svc = serviceReturning(<String, dynamic>{});
      await svc.llpCurrentProfile('LLP0012345-LGN');

      expect(sentAction, 'llpCurrentProfile');
      expect(sentParams['entityNoOldFormat'], 'LLP0012345-LGN');
    });

    test('a document list comes back as documents', () async {
      final svc = serviceReturning({
        'documentInfos': {
          'documentInfos': [
            {
              'verId': '2026737',
              'formType': 'Annual Return',
              'documentDate': '2025-06-30',
              'totalPage': '4',
            },
          ],
        },
      });
      final docs = await svc.imageView('199301012345');

      expect(sentAction, 'imageView');
      expect(docs.single.verId, '2026737');
      expect(docs.single.formType, 'Annual Return');
    });

    test('a document is fetched by its version id', () async {
      final svc = serviceReturning({'docContent': 'JVBERi0xLjQK'});
      final content = await svc.image('199301012345', '2026737');

      expect(sentAction, 'image');
      expect(sentParams['verId'], '2026737');
      expect(content, 'JVBERi0xLjQK');
    });

    test('a profile dispatches on the entity type', () async {
      final svc = serviceReturning(<String, dynamic>{});
      await svc.profile(
        entityType: 'limited_liability_partnerships',
        newRegNo: '201901030189',
        oldRegNo: 'LLP0012345-LGN',
      );

      expect(sentAction, 'profile');
      expect(sentParams['entityType'], 'limited_liability_partnerships');
      // BOTH numbers go, because which one the right endpoint wants
      // depends on the type and the edge function is the one that
      // knows.
      expect(sentParams['newRegNo'], '201901030189');
      expect(sentParams['oldRegNo'], 'LLP0012345-LGN');
    });

    test('force is sent only when asked for', () async {
      final svc = serviceReturning(<String, dynamic>{});
      await svc.companyProfile('199301012345');
      expect(sentParams.containsKey('force'), isFalse);

      await svc.companyProfile('199301012345', force: true);
      expect(sentParams['force'], isTrue);
    });
  });

  group('what a failure says', () {
    test('a refused key is not something to try again', () {
      const e = SsmApiException(kind: 'auth', message: 'whatever');
      expect(e.isCredentialProblem, isTrue);
      expect(e.userMessage, contains('platform admin'));
    });

    test('a rate limit says to wait', () {
      const e = SsmApiException(kind: 'rate_limited', message: 'whatever');
      expect(e.isRateLimited, isTrue);
      expect(e.userMessage, contains('wait'));
    });

    test('the reference is read under the name the function sends', () {
      // `client_ref_no`, which is what SSM's own support asks for. Read
      // under any other name it is null at exactly the moment somebody
      // needs it.
      final e = SsmApiException.fromJson({
        'kind': 'upstream',
        'message': 'no record',
        'client_ref_no': 'org-1:abc',
      });
      expect(e.clientRefNo, 'org-1:abc');
    });
  });
}

/// A client the tests never call through.
///
/// `SsmSearchService` takes a concrete `SupabaseClient`, which cannot be
/// faked; every test above supplies an `invoker` instead, so this is
/// only ever the unused first argument.
final _unusedClient = SupabaseClient(
  'https://example.invalid',
  'not-a-key',
);
