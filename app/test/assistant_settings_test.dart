import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/core/providers.dart';
import 'package:iakauntan/src/core/theme.dart';
import 'package:iakauntan/src/data/repository.dart';
import 'package:iakauntan/src/features/ai/assistant_settings_sheet.dart';

/// The assistant sheet, for a company nobody ever switched to.
///
/// Reported from a phone, of this sheet, as three words: "Why can't
/// save". It could not, and nothing said so — the button called
/// nothing, showed no snackbar and left no trace.
///
///     final org = ref.read(currentOrgIdProvider);
///     if (org == null) return;
///
/// `currentOrgIdProvider` is the company SWITCHER's selection. It is
/// null until somebody switches company, which most people never do,
/// so that early return was the ordinary case rather than the edge one.
/// The same sheet's status card said "Not ready to answer yet" over the
/// word **null**, because `aiStatusProvider` had the same fault and
/// handed the card an empty map, whose absent keys were interpolated
/// into a string.
///
/// **Every test in this file leaves `currentOrgIdProvider` at its
/// default**, which is null. That is not an oversight; it is the
/// condition being tested, and overriding it would test the one case
/// that always worked.
void main() {
  late _FakeRepo repo;

  setUp(() => repo = _FakeRepo());

  Widget wrap() => ProviderScope(
        overrides: [
          repoProvider.overrideWithValue(repo),
          // Deliberately NOT overriding currentOrgIdProvider: null is
          // the reported condition.
          aiProvidersProvider.overrideWith((ref) async => const [
                {
                  'code': 'google',
                  'name': 'Google Gemini',
                  'wire': 'openai',
                  'base_url': 'https://generativelanguage.googleapis.com',
                  'is_active': true,
                },
              ]),
          aiModelsProvider.overrideWith((ref) async => const [
                {
                  'provider_code': 'google',
                  'model_id': 'gemini-2.0-flash',
                  'name': 'Gemini 2.0 Flash',
                  'kind': 'chat',
                  'is_active': true,
                },
              ]),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const Scaffold(body: AssistantSettingsSheet()),
        ),
      );

  Future<void> open(WidgetTester tester) async {
    await tester.pumpWidget(wrap());
    await tester.pump();
    await tester.pump();
  }

  testWidgets('Save saves, on a company that was never switched to',
      (tester) async {
    await open(tester);

    await tester.tap(find.byKey(const ValueKey('assistant-save')));
    await tester.pump();
    await tester.pump();

    final call = repo.calls
        .where((c) => c.key == 'set_ai_settings')
        .firstOrNull;
    expect(call, isNotNull,
        reason: 'Save called nothing at all, which is the report');
    // Against the repository's own company, which is the one every
    // other call on this screen is already scoped to.
    expect(call!.value['p_org_id'], 'o1');
  });

  testWidgets('and says so, rather than doing nothing quietly',
      (tester) async {
    await open(tester);
    await tester.tap(find.byKey(const ValueKey('assistant-save')));
    await tester.pump();
    await tester.pump();
    expect(find.text('Saved'), findsOneWidget);
  });

  // The other half of the same screenshot. `ai_status` always answers
  // with a provider and a reason, so an empty map means the call did
  // not happen -- and whatever the reason for that, the card must not
  // print the four characters of a Dart null.
  testWidgets('a status with nothing in it does not render as "null"',
      (tester) async {
    repo.status = const [];
    await open(tester);

    expect(find.text('null'), findsNothing);
    expect(find.textContaining('Nothing is set up yet'), findsOneWidget);
  });

  // And the ordinary case still reads the way it always did.
  testWidgets('a real reason is shown as the reason', (tester) async {
    repo.status = const [
      {
        'is_enabled': true,
        'provider_code': 'google',
        'provider_name': 'Google Gemini',
        'model_id': null,
        'key_source': 'platform',
        'follows_platform': false,
        'has_own_key': false,
        'is_ready': false,
        'not_ready_reason': 'No model is chosen, and the platform has '
            'not named a default one.',
      },
    ];
    await open(tester);

    expect(find.textContaining('No model is chosen'), findsOneWidget);
    expect(find.text('null'), findsNothing);
  });
}

/// A repository that answers `ai_status` and records what was sent.
///
/// `callRpc` and not the extension methods: a Dart extension binds to
/// the static type, so `@override` on `setAiSettings` would not be one
/// and the real extension would run regardless.
class _FakeRepo implements Repo {
  final List<MapEntry<String, Map<String, dynamic>>> calls = [];

  List<Map<String, dynamic>> status = const [
    {
      'is_enabled': false,
      'provider_code': 'anthropic',
      'provider_name': 'Anthropic',
      'model_id': 'claude-opus-5',
      'model_name': 'Claude Opus 5',
      'key_source': 'platform',
      'follows_platform': true,
      'has_own_key': false,
      'is_ready': false,
      'not_ready_reason': 'The platform has no key on file for Anthropic.',
    },
  ];

  @override
  String get orgId => 'o1';

  @override
  Future<dynamic> callRpc(String fn, {Map<String, dynamic>? params}) async {
    calls.add(MapEntry(fn, params ?? const {}));
    if (fn == 'ai_status') return status;
    return null;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
        'the assistant sheet called Repo.${invocation.memberName}, '
        'which this fake does not answer',
      );
}
