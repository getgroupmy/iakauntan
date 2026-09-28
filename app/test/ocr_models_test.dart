import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/core/providers.dart';
import 'package:iakauntan/src/core/theme.dart';
import 'package:iakauntan/src/data/ocr_repository.dart';
import 'package:iakauntan/src/data/repository.dart';
import 'package:iakauntan/src/features/admin/ocr_catalog_admin.dart';

/// Asking a vendor what models its key can reach, instead of typing one
/// from memory.
///
/// `0113` seeded `ocr_providers` with `model` null on ChatGPT and Grok
/// and said why — "guessing an identifier would produce a migration that
/// looks finished and a 404 at the first scan, blamed on the feature
/// rather than on the guess". That reasoning is still right, and nothing
/// in this change invents a model either.
///
/// What was wrong was the other half. An operator was left to type an
/// identifier they had to already know, from a vendor that renames its
/// models every few months, into a free-text field that accepts anything
/// and only fails at the FIRST SCAN — by which time `ocr_begin` has
/// taken a tenant's credit for it.
///
/// So most of what is asserted here is about not lying:
///
///   * the id that gets stored is the id the operator SAW, never a
///     display name they did not;
///   * an empty list from a vendor that answered is said out loud,
///     because silence reads as a button that does not work;
///   * a refusal is shown in the vendor's own words, under the field it
///     is about;
///   * and nothing is asked about a reader that has not been saved,
///     because there is no endpoint and no key to ask with.
void main() {
  group('one model, as the console has to show it', () {
    test('the id is what is stored and the label is only for reading', () {
      const m = OcrModelChoice(id: 'claude-opus-5', label: 'Claude Opus 5');
      expect(m.id, 'claude-opus-5');
      // Both, and the id is in it: a list of display names would have
      // somebody pick "Claude Opus 5" and store something they never
      // saw.
      expect(m.shown, contains('claude-opus-5'));
      expect(m.shown, contains('Claude Opus 5'));
    });

    test('a model with no display name is not shown twice', () {
      const m = OcrModelChoice(id: 'gpt-4o', label: 'gpt-4o');
      expect(m.shown, 'gpt-4o');
    });

    test('a missing label falls back to the id rather than being blank', () {
      // OpenAI's list carries no display name at all, so this is the
      // ordinary case and not the edge one.
      final m = OcrModelChoice.fromJson(const {'id': 'gpt-4o'});
      expect(m.label, 'gpt-4o');
      expect(m.shown, 'gpt-4o');
    });

    test('whitespace around an id is not part of it', () {
      final m = OcrModelChoice.fromJson(const {'id': '  gpt-4o  '});
      expect(m.id, 'gpt-4o');
    });

    test('an answer with no id at all reads as empty, not as null', () {
      expect(OcrModelChoice.fromJson(const {}).id, isEmpty);
    });
  });

  group('the reader editor', () {
    Widget harness(
      _FakePlatform platform,
      List<Map<String, dynamic>> readers,
    ) => ProviderScope(
      overrides: [
        platformRepoProvider.overrideWithValue(platform),
        ocrProviderCatalogProvider.overrideWith((ref) async => readers),
        ocrDefaultProviderProvider.overrideWith(
          (ref) async => const OcrDefaultState(
            provider: 'gemini',
            name: 'Gemini',
            price: 0,
            isFree: true,
            isFallback: true,
            runsOnDevice: false,
          ),
        ),
      ],
      child: MaterialApp(
        theme: AppTheme.light(),
        home: const OcrCatalogAdminTab(),
      ),
    );

    // Active, chargeable, and with no model. `0113` ships ChatGPT this
    // way on purpose, and it is the row this whole change is about.
    const chatgpt = {
      'code': 'openai',
      'name': 'ChatGPT',
      'kind': 'openai',
      'endpoint': 'https://api.openai.com/v1/chat/completions',
      'model': null,
      'price': 0.30,
      'takes_key': true,
      'runs_on_device': false,
      'is_active': true,
    };

    /// What is in the Model box -- the one field whose contents become
    /// `ocr_providers.model`.
    String? modelBox(WidgetTester tester) => tester
        .widget<TextField>(find.byKey(const ValueKey('reader-model')))
        .controller
        ?.text;

    Future<void> openEditor(WidgetTester tester, _FakePlatform p) async {
      tester.view.physicalSize = const Size(1200, 2200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(harness(p, const [chatgpt]));
      await tester.pumpAndSettle();
      // The row itself opens the editor; there is no pencil.
      await tester.tap(find.text('ChatGPT'));
      await tester.pumpAndSettle();
    }

    testWidgets('asks the vendor about the reader being edited', (tester) async {
      final p = _FakePlatform(models: const [
        OcrModelChoice(id: 'gpt-4o', label: 'gpt-4o'),
      ]);
      await openEditor(tester, p);

      // Nothing is asked until somebody asks. An editor that fetched on
      // open would spend a round trip to every vendor for an operator
      // who came to correct a price.
      expect(p.asked, isEmpty);

      await tester.tap(find.byKey(const ValueKey('ask-vendor-for-models')));
      await tester.pumpAndSettle();

      // The reader's CODE, not whatever is in the name box.
      expect(p.asked, ['openai']);
      expect(
        find.byKey(const ValueKey('model-from-vendor')),
        findsOneWidget,
      );
    });

    testWidgets('choosing a model fills the box that gets saved', (
      tester,
    ) async {
      final p = _FakePlatform(models: const [
        OcrModelChoice(id: 'gpt-4o', label: 'gpt-4o'),
        OcrModelChoice(id: 'gpt-4o-mini', label: 'gpt-4o-mini'),
      ]);
      await openEditor(tester, p);
      await tester.tap(find.byKey(const ValueKey('ask-vendor-for-models')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('model-from-vendor')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('gpt-4o-mini').last);
      await tester.pumpAndSettle();

      // Into the Model FIELD, so what is about to be saved is visible in
      // the same box it would have been typed into.
      expect(modelBox(tester), 'gpt-4o-mini');
    });

    testWidgets('the id lands in the box, never the display name', (
      tester,
    ) async {
      // The failure this exists to stop: a picker keyed on display names
      // would put "Claude Opus 5" in the box, which no vendor's API
      // accepts, and the 404 would arrive at somebody's first scan --
      // after `ocr_begin` had already taken their credit for it.
      final p = _FakePlatform(models: const [
        OcrModelChoice(id: 'claude-opus-5', label: 'Claude Opus 5'),
      ]);
      await openEditor(tester, p);
      await tester.tap(find.byKey(const ValueKey('ask-vendor-for-models')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('model-from-vendor')));
      await tester.pumpAndSettle();

      // Both are in the open list -- the display name is how somebody
      // recognises the row -- and only one of them is what gets chosen.
      expect(find.textContaining('Claude Opus 5'), findsWidgets);
      expect(find.text('claude-opus-5'), findsWidgets);

      await tester.tap(find.text('claude-opus-5').last);
      await tester.pumpAndSettle();

      expect(modelBox(tester), 'claude-opus-5');
    });

    testWidgets('a vendor that lists nothing says so', (tester) async {
      final p = _FakePlatform(models: const []);
      await openEditor(tester, p);
      await tester.tap(find.byKey(const ValueKey('ask-vendor-for-models')));
      await tester.pumpAndSettle();

      // Silence here reads as the button not working, and sends somebody
      // to check their network instead of their key's project scope.
      expect(find.textContaining('listed no models'), findsOneWidget);
      expect(find.byKey(const ValueKey('model-from-vendor')), findsNothing);
    });

    testWidgets('a refusal is shown in the vendor\'s own words', (
      tester,
    ) async {
      final p = _FakePlatform(
        problem: OcrModelsException('ChatGPT refused: incorrect API key '
            'provided'),
      );
      await openEditor(tester, p);
      await tester.tap(find.byKey(const ValueKey('ask-vendor-for-models')));
      await tester.pumpAndSettle();

      // "Incorrect API key provided" is the whole answer. Replacing it
      // with "that did not work" sends somebody to read logs for what
      // they had already been told.
      expect(find.textContaining('incorrect API key'), findsOneWidget);
      expect(find.byKey(const ValueKey('model-from-vendor')), findsNothing);
    });

    testWidgets('a refusal after a good answer clears the stale list', (
      tester,
    ) async {
      final p = _FakePlatform(models: const [
        OcrModelChoice(id: 'gpt-4o', label: 'gpt-4o'),
      ]);
      await openEditor(tester, p);
      await tester.tap(find.byKey(const ValueKey('ask-vendor-for-models')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('model-from-vendor')), findsOneWidget);

      // The key is revoked between one ask and the next. A list left on
      // screen beside an error is a list somebody would pick from.
      p.problem = OcrModelsException('ChatGPT refused: invalid key');
      await tester.tap(find.byKey(const ValueKey('ask-vendor-for-models')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('model-from-vendor')), findsNothing);
      expect(find.textContaining('invalid key'), findsOneWidget);
    });

    testWidgets('a reader that does not exist yet cannot be asked', (
      tester,
    ) async {
      final p = _FakePlatform(models: const []);
      tester.view.physicalSize = const Size(1200, 2200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(harness(p, const [chatgpt]));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add a reader'));
      await tester.pumpAndSettle();

      // There is no endpoint and no key on the server for a row being
      // typed, and asking about a half-typed code would report "there is
      // no reader called ope".
      expect(find.byKey(const ValueKey('ask-vendor-for-models')), findsNothing);
      // And says what to do instead, rather than only not offering it.
      expect(
        find.textContaining('Save the reader, then ask its vendor'),
        findsOneWidget,
      );
      expect(p.asked, isEmpty);
    });
  });
}

class _FakePlatform implements PlatformRepo {
  _FakePlatform({this.models, this.problem});

  final List<OcrModelChoice>? models;
  OcrModelsException? problem;

  /// Every reader the console asked about, in order. The assertion is as
  /// much about the LENGTH as the contents: opening the editor must not
  /// call a vendor.
  final List<String> asked = [];

  @override
  Future<List<OcrModelChoice>> ocrModels(String code) async {
    asked.add(code);
    final p = problem;
    if (p != null) throw p;
    return models ?? const [];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
        'the reader editor called PlatformRepo.${invocation.memberName}, '
        'which this fake does not answer',
      );
}
