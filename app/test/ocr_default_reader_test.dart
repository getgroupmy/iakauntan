import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/core/providers.dart';
import 'package:iakauntan/src/core/theme.dart';
import 'package:iakauntan/src/data/ocr_repository.dart';
import 'package:iakauntan/src/features/admin/ocr_catalog_admin.dart';

/// Which reader a company gets, and which one reads the document when
/// that one will not. `0678` and `0679`.
///
/// The bug that started it was one sentence on a live screen —
/// `Claude is not available` — and three separate things had to be
/// true for it to happen, none of which is a coding slip:
///
///   * the reader an unchosen company fell back to was a string
///     literal in a function body, so the console could not change it;
///   * the settings card echoed that literal back on the toggle, so
///     the company asked for a reader it had never wanted;
///   * and the reader list was drawn only when scanning was ON, so the
///     control that fixes it was behind the door it had locked.
///
/// Most of what is asserted here is text, and it is text somebody
/// reads while deciding whether to spend money or whether to worry.
/// The two that matter most are about the FALLBACK, because it runs
/// without asking: a company has to be told before it happens, and a
/// platform has to be told when pricing a reader has silently switched
/// it off.
void main() {
  OcrSettings status({
    bool enabled = true,
    String provider = 'gemini',
    String? fallback,
    String? fallbackName,
    double price = 0.30,
    bool chosen = true,
    List<OcrProvider> providers = const [],
  }) => OcrSettings(
    enabled: enabled,
    provider: provider,
    keySource: 'platform',
    hasOwnKey: false,
    keys: const {},
    balance: 100,
    price: price,
    chosen: chosen,
    defaultProvider: 'gemini',
    fallback: fallback,
    fallbackName: fallbackName,
    providers: providers,
  );

  OcrProvider reader({
    String code = 'gemini',
    String name = 'Gemini',
    double price = 0.30,
    bool isActive = true,
    bool onDevice = false,
  }) => OcrProvider(
    code: code,
    name: name,
    price: price,
    takesKey: true,
    runsOnDevice: onDevice,
    ready: true,
    isActive: isActive,
  );

  group('what the status says about a reader that is gone', () {
    test('a company on a retired reader is told so', () {
      final s = status(
        provider: 'claude',
        providers: [reader(code: 'claude', name: 'Claude', isActive: false)],
      );
      expect(s.retired, isTrue);
    });

    test('a company on a reader that is still offered is not', () {
      expect(status(providers: [reader()]).retired, isFalse);
    });

    // The distinction the whole of 0678 rests on. A reader the app has
    // never heard of is not the same as a retired one: `ocr_status`
    // lists the active readers PLUS the one this company is on, so a
    // reader missing from that list entirely is a database older than
    // this build, and guessing `retired` from it would put a warning
    // on a screen with nothing wrong.
    test('a reader missing from the list is not called retired', () {
      expect(status(provider: 'nobody-has-heard-of-this').retired, isFalse);
    });

    // The reported bug, as a decision rather than as pixels. The
    // reader list lived inside `if (ocr.enabled)`, and a company whose
    // reader had been retired could not switch scanning on — the save
    // refuses a retired reader — so the only way to change the reader
    // was through the door the reader had locked.
    test('a company on a retired reader must be shown the list anyway', () {
      final stuck = status(
        enabled: false,
        provider: 'claude',
        providers: [reader(code: 'claude', name: 'Claude', isActive: false)],
      );
      expect(stuck.mustChooseAnother, isTrue);
    });

    test('and a company that simply has scanning off is not', () {
      expect(
        status(enabled: false, providers: [reader()]).mustChooseAnother,
        isFalse,
      );
    });

    // With scanning ON the list is drawn anyway, so this must not be
    // the thing that draws it — a widget that drew the list only when
    // `mustChooseAnother` was true would take it away from everybody
    // who is scanning normally.
    test('and a company scanning on a retired reader is not either', () {
      final s = status(
        enabled: true,
        provider: 'claude',
        providers: [reader(code: 'claude', name: 'Claude', isActive: false)],
      );
      expect(s.retired, isTrue);
      expect(s.mustChooseAnother, isFalse);
    });

    test('whether the reader was this company\'s own choice', () {
      expect(status(chosen: false).chosen, isFalse);
      expect(status(chosen: true).chosen, isTrue);
    });
  });

  group('reading the status off the wire', () {
    test('the new fields arrive', () {
      final s = OcrSettings.fromJson(const {
        'enabled': true,
        'provider': 'claude',
        'default_provider': 'gemini',
        'chosen': true,
        'fallback': 'gemini',
        'fallback_name': 'Gemini',
        'key_source': 'platform',
        'balance': 12.5,
        'price': 0.3,
        'providers': [
          {
            'code': 'claude',
            'name': 'Claude',
            'price': 0.3,
            'takes_key': true,
            'is_active': false,
            'ready': true,
          },
        ],
      });
      expect(s.defaultProvider, 'gemini');
      expect(s.chosen, isTrue);
      expect(s.fallback, 'gemini');
      expect(s.fallbackName, 'Gemini');
      expect(s.retired, isTrue);
    });

    // A database that predates 0678 sends none of this, and the screen
    // has to draw rather than throw. `is_active` absent must read as
    // ACTIVE: reading a missing field as retired would put the
    // "no longer offered" warning on every company on the old schema.
    test('an older database leaves them null and nothing is retired', () {
      final s = OcrSettings.fromJson(const {
        'enabled': true,
        'provider': 'claude',
        'key_source': 'platform',
        'balance': 0,
        'price': 0.3,
        'providers': [
          {'code': 'claude', 'name': 'Claude', 'price': 0.3},
        ],
      });
      expect(s.defaultProvider, isNull);
      expect(s.fallback, isNull);
      expect(s.chosen, isFalse);
      expect(s.retired, isFalse);
    });
  });

  group('what the console is told the default is doing', () {
    test('a free default is also the fallback', () {
      final d = OcrDefaultState.fromJson(const {
        'provider': 'gemini',
        'name': 'Gemini',
        'price': 0,
        'is_free': true,
        'is_fallback': true,
        'runs_on_device': false,
      });
      expect(d.isFree, isTrue);
      expect(d.isFallback, isTrue);
    });

    // The one an operator would never work out on their own: pricing
    // the default reader does not just change a number, it switches
    // the fallback off for every company on the platform.
    test('a priced default is not', () {
      final d = OcrDefaultState.fromJson(const {
        'provider': 'gemini',
        'name': 'Gemini',
        'price': 0.2,
        'is_free': false,
        'is_fallback': false,
        'runs_on_device': false,
      });
      expect(d.isFree, isFalse);
      expect(d.isFallback, isFalse);
    });

    test('an empty answer does not pretend there is a default', () {
      expect(OcrDefaultState.fromJson(const {}).provider, isEmpty);
      expect(OcrDefaultState.fromJson(const {}).isFallback, isFalse);
    });
  });

  group('the console page', () {
    Widget harness(
      List<Map<String, dynamic>> readers,
      OcrDefaultState current,
    ) => ProviderScope(
      overrides: [
        ocrProviderCatalogProvider.overrideWith((ref) async => readers),
        ocrDefaultProviderProvider.overrideWith((ref) async => current),
      ],
      child: MaterialApp(
        theme: AppTheme.light(),
        home: const OcrCatalogAdminTab(),
      ),
    );

    const free = {
      'code': 'gemini',
      'name': 'Gemini',
      'kind': 'openai',
      'model': 'gemini-2.0-flash',
      'price': 0,
      'takes_key': true,
      'is_active': true,
    };
    const paid = {
      'code': 'claude',
      'name': 'Claude',
      'kind': 'anthropic',
      'model': 'claude-opus-5',
      'price': 0.30,
      'takes_key': true,
      'is_active': true,
    };
    const retired = {
      'code': 'mlkit',
      'name': 'On this device',
      'kind': 'device',
      'model': null,
      'price': 0,
      'takes_key': false,
      'is_active': false,
    };
    // Active, and with no model. 0113 ships it that way on purpose.
    const unfinished = {
      'code': 'openai',
      'name': 'ChatGPT',
      'kind': 'openai',
      'model': null,
      'price': 0.30,
      'takes_key': true,
      'is_active': true,
    };

    const geminiIsDefault = OcrDefaultState(
      provider: 'gemini',
      name: 'Gemini',
      price: 0,
      isFree: true,
      isFallback: true,
      runsOnDevice: false,
    );

    testWidgets('says the free default is also the fallback', (tester) async {
      tester.view.physicalSize = const Size(1200, 1800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(harness([free, paid], geminiIsDefault));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('default-reader')), findsOneWidget);
      expect(
        find.textContaining('it is also the fallback'),
        findsOneWidget,
      );
      expect(find.textContaining('at no charge to them'), findsOneWidget);
    });

    testWidgets('warns when a priced default leaves no fallback', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1200, 1800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        harness([free, paid], const OcrDefaultState(
          provider: 'claude',
          name: 'Claude',
          price: 0.30,
          isFree: false,
          isFallback: false,
          runsOnDevice: false,
        )),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('There is no fallback'), findsOneWidget);
      // And says how to get one back, rather than only that there
      // isn't one.
      expect(
        find.textContaining('Mark a reader free and make it the default'),
        findsOneWidget,
      );
    });

    testWidgets('a reader that cannot be chosen is not offered as the '
        'default', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1200, 1800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        harness([free, unfinished, retired], geminiIsDefault),
      );
      await tester.pumpAndSettle();

      // Read off the dropdown itself rather than off the screen: the
      // catalog list below it names every reader including this one,
      // so `find.text('ChatGPT')` answers a different question.
      final items = tester
          .widget<DropdownButton<String>>(
            find.descendant(
              of: find.byKey(const ValueKey('default-reader')),
              matching: find.byType(DropdownButton<String>),
            ),
          )
          .items!
          .map((i) => i.value)
          .toList();
      // `platform_set_default_ocr_provider` refuses both of these --
      // no model, and switched off -- so offering either would be
      // offering a choice whose save cannot succeed. The retired one
      // is in the list for a second reason: a reader nobody can pick
      // cannot be what everybody falls back to.
      expect(items, ['gemini']);
    });

    testWidgets('a catalog with nothing usable says why', (tester) async {
      tester.view.physicalSize = const Size(1200, 1800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        harness([unfinished], OcrDefaultState.none),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('default-reader')), findsNothing);
      expect(
        find.textContaining('Switch one on and give it a model'),
        findsOneWidget,
      );
    });

    testWidgets('the list says free rather than RM 0.00 a scan', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1200, 1800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(harness([free, paid], geminiIsDefault));
      await tester.pumpAndSettle();

      expect(find.text('Free'), findsOneWidget);
      expect(find.text('RM 0.00 / scan'), findsNothing);
      expect(find.text('RM 0.30 / scan'), findsOneWidget);
    });
  });
}
