import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/core/providers.dart';
import 'package:iakauntan/src/core/theme.dart';
import 'package:iakauntan/src/data/ocr_repository.dart';
import 'package:iakauntan/src/data/repository.dart';
import 'package:iakauntan/src/features/admin/platform_console_screen.dart';
import 'package:iakauntan/src/features/admin/scan_settings_admin.dart';
import 'package:iakauntan/src/features/banking/bank_statements_screen.dart';
import 'package:iakauntan/src/features/smartscan/smartscan_screen.dart';
import 'package:iakauntan/src/features/smartscan/smartscan_settings.dart';

/// The five scanning surface switches, from the console and from the
/// screens they take controls off. `0718`.
///
/// What is asserted here is the SCREEN half. The database half — whose
/// key pays, and whether a company that never chose has scanning on —
/// is in `supabase/tests/scan_surfaces.sql`, because a rule enforced
/// only in Dart is not enforced.
void main() {
  Widget wrap(
    Widget child, {
    ScanSurfaces? surfaces,
    Repo? repo,
    _FakePlatform? platform,
  }) =>
      ProviderScope(
        overrides: [
          repoProvider.overrideWithValue(repo ?? _FakeRepo()),
          // The console page reads the PLATFORM repository, because
          // neither call takes an organization and a console pane must
          // not wait on one.
          platformRepoProvider
              .overrideWithValue(platform ?? _FakePlatform()),
          memberRoleProvider.overrideWith((ref) async => 'owner'),
          if (surfaces != null)
            scanSurfacesProvider.overrideWith((ref) async => surfaces),
          scanInboxProvider.overrideWith((ref, only) async => const []),
          bankAccountsProvider.overrideWith((ref) async => const [
                {'id': 'b1', 'name': 'Maybank Current', 'bank_name': 'Maybank'},
              ]),
        ],
        // A console tab is drawn inside the console's own Scaffold,
        // so it has Material above it there and needs one here.
        child: MaterialApp(
          theme: AppTheme.light(),
          home: child is Scaffold ? child : Scaffold(body: child),
        ),
      );

  group('a switch nobody has touched takes nothing off the screen', () {
    test('every surface starts present', () {
      const s = ScanSurfaces();
      expect(s.scanButton, isTrue);
      expect(s.uploadButton, isTrue);
      expect(s.ownKey, isTrue);
      expect(s.statementsUpload, isTrue);
    });

    test('except the one that costs money and sends paperwork away', () {
      // The wrong answer here is not a missing button: it is somebody's
      // bank statement at a third-party model without being asked.
      expect(const ScanSurfaces().readerOnByDefault, isFalse);
    });

    test('a payload missing a key keeps that surface, not loses it', () {
      final s = ScanSurfaces.from(const {'scan_button': false});
      expect(s.scanButton, isFalse);
      expect(s.uploadButton, isTrue);
      expect(s.statementsUpload, isTrue);
      // And the exception stays the exception.
      expect(s.readerOnByDefault, isFalse);
    });

    test('a value that is not a boolean is not read as false', () {
      // A server answering `null` — or a string, or nothing at all —
      // must not be the same as an operator switching a surface off.
      final s = ScanSurfaces.from(const {
        'scan_button': null,
        'upload_button': 'true',
        'statements_upload': 1,
      });
      expect(s.scanButton, isTrue);
      expect(s.uploadButton, isTrue);
      expect(s.statementsUpload, isTrue);
    });

    test('the two Upload switches are two switches', () {
      // They are the only pair whose names are near enough to be wired
      // to each other by mistake, and a fixture that turns both off
      // cannot tell the difference. One off, one on.
      final s = ScanSurfaces.from(const {
        'upload_button': false,
        'statements_upload': true,
      });
      expect(s.uploadButton, isFalse);
      expect(s.statementsUpload, isTrue);

      final t = ScanSurfaces.from(const {
        'upload_button': true,
        'statements_upload': false,
      });
      expect(t.uploadButton, isTrue);
      expect(t.statementsUpload, isFalse);
    });

    test('and the switches are read off the names the database sends', () {
      final s = ScanSurfaces.from(const {
        'scan_button': false,
        'upload_button': false,
        'own_key': false,
        'reader_on_default': true,
        'statements_upload': false,
      });
      expect(s.scanButton, isFalse);
      expect(s.uploadButton, isFalse);
      expect(s.ownKey, isFalse);
      expect(s.readerOnByDefault, isTrue);
      expect(s.statementsUpload, isFalse);
    });
  });

  group('AI SmartScan', () {
    testWidgets('offers both buttons while the platform offers them',
        (tester) async {
      await tester.pumpWidget(wrap(const SmartScanScreen(),
          surfaces: const ScanSurfaces()));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('smartscan-new')), findsOneWidget);
      expect(find.byKey(const ValueKey('smartscan-keep')), findsOneWidget);
    });

    testWidgets('and drops the Scan button on its own', (tester) async {
      await tester.pumpWidget(wrap(const SmartScanScreen(),
          surfaces: const ScanSurfaces(scanButton: false)));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('smartscan-new')), findsNothing);
      // One switch, one button. Taking both off with one toggle would
      // be a switch that does not do what its label says.
      expect(find.byKey(const ValueKey('smartscan-keep')), findsOneWidget);
    });

    testWidgets('and the Upload button on its own', (tester) async {
      await tester.pumpWidget(wrap(const SmartScanScreen(),
          surfaces: const ScanSurfaces(uploadButton: false)));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('smartscan-keep')), findsNothing);
      expect(find.byKey(const ValueKey('smartscan-new')), findsOneWidget);
    });
  });

  group('Bank statements', () {
    testWidgets('offers Upload beside an account', (tester) async {
      await tester.pumpWidget(wrap(const BankStatementsScreen(),
          surfaces: const ScanSurfaces()));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('bank-statement-upload-b1')),
          findsOneWidget);
    });

    testWidgets('and drops it when the platform has', (tester) async {
      await tester.pumpWidget(wrap(const BankStatementsScreen(),
          surfaces: const ScanSurfaces(statementsUpload: false)));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('bank-statement-upload-b1')),
          findsNothing);
      // The account is still there, and still opens. This switch takes
      // away a shortcut, not the statement screen.
      expect(find.byKey(const ValueKey('bank-statement-account-b1')),
          findsOneWidget);
    });
  });

  group('whose key pays', () {
    test('the option is offered while the platform allows it', () {
      expect(
        OcrSettings.fromJson(const {'own_key_allowed': true}).ownKeyAllowed,
        isTrue,
      );
    });

    test('and withdrawn when it does not', () {
      expect(
        OcrSettings.fromJson(const {'own_key_allowed': false}).ownKeyAllowed,
        isFalse,
      );
    });

    test('a server that does not send it leaves the option alone', () {
      // An app talking to a deployment older than `0718`. Reading a
      // missing field as "not allowed" would take the choice away from
      // every company on it.
      expect(OcrSettings.fromJson(const {}).ownKeyAllowed, isTrue);
    });

    test('the card offers the choice while the platform allows it', () {
      expect(offerKeySourceChoice(_ocr(allowed: true), 'platform'), isTrue);
    });

    test('and stops offering it once withdrawn', () {
      expect(offerKeySourceChoice(_ocr(allowed: false), 'platform'), isFalse);
    });

    test('but never strands a company already on its own key', () {
      // Hiding the control here would leave them on a key they could
      // not move off. `set_ocr_settings` lets them move BACK, which is
      // the only reason this case exists.
      expect(offerKeySourceChoice(_ocr(allowed: false), 'own'), isTrue);
    });

    test('a reader that takes no key is not asked whose key pays', () {
      expect(
        offerKeySourceChoice(_ocr(allowed: true, takesKey: false), 'platform'),
        isFalse,
      );
      // Even for a company recorded as being on its own key: Local Read
      // calls nobody, so there is nothing to pay for either way.
      expect(
        offerKeySourceChoice(_ocr(allowed: false, takesKey: false), 'own'),
        isFalse,
      );
    });
  });

  group('the console page', () {
    testWidgets('draws all five switches', (tester) async {
      await tester.pumpWidget(wrap(const ScanSettingsAdminTab(),
          surfaces: const ScanSurfaces()));
      await tester.pumpAndSettle();

      for (final key in const [
        'scan_show_scan_button',
        'scan_show_upload_button',
        'statements_show_upload_button',
        'scan_allow_own_key',
        'scan_reader_on_by_default',
      ]) {
        expect(find.byKey(ValueKey('scan-surface-$key')), findsOneWidget,
            reason: '$key has no switch on the page');
      }
    });

    testWidgets('says which of them are presentation', (tester) async {
      // An operator who believes the Scan button is a security control
      // has been misled by a screen, which is worse than no screen.
      await tester.pumpWidget(wrap(const ScanSettingsAdminTab(),
          surfaces: const ScanSurfaces()));
      await tester.pumpAndSettle();

      expect(find.textContaining('These three are presentation'),
          findsOneWidget);
      expect(find.textContaining('it does not stop scanning'),
          findsOneWidget);
    });

    testWidgets('and warns about the one that spends money', (tester) async {
      await tester.pumpWidget(wrap(const ScanSettingsAdminTab(),
          surfaces: const ScanSurfaces(readerOnByDefault: true)));
      await tester.pumpAndSettle();

      expect(find.textContaining('third-party model'), findsOneWidget);
      expect(find.textContaining('charged to platform credit'),
          findsOneWidget);
    });

    testWidgets('and says nothing of the sort while it is off',
        (tester) async {
      await tester.pumpWidget(wrap(const ScanSettingsAdminTab(),
          surfaces: const ScanSurfaces()));
      await tester.pumpAndSettle();

      expect(find.textContaining('third-party model'), findsNothing);
    });

    testWidgets('moving one sends that key and no other', (tester) async {
      final platform = _FakePlatform();
      await tester.pumpWidget(wrap(const ScanSettingsAdminTab(),
          surfaces: const ScanSurfaces(), platform: platform));
      await tester.pumpAndSettle();

      // The second card is below the fold on a test surface.
      final target =
          find.byKey(const ValueKey('scan-surface-scan_allow_own_key'));
      await tester.ensureVisible(target);
      await tester.pumpAndSettle();
      await tester.tap(target);
      await tester.pumpAndSettle();

      expect(platform.moved, {'key': 'scan_allow_own_key', 'on': false});
    });

    testWidgets('and turning the reader default on sends true',
        (tester) async {
      final platform = _FakePlatform();
      await tester.pumpWidget(wrap(const ScanSettingsAdminTab(),
          surfaces: const ScanSurfaces(), platform: platform));
      await tester.pumpAndSettle();

      final target = find.byKey(
        const ValueKey('scan-surface-scan_reader_on_by_default'),
      );
      await tester.ensureVisible(target);
      await tester.pumpAndSettle();
      await tester.tap(target);
      await tester.pumpAndSettle();

      expect(
          platform.moved, {'key': 'scan_reader_on_by_default', 'on': true});
    });
  });

  group('reachable from the console', () {
    test('the page is on the menu', () {
      expect(
        platformConsoleSections.any((s) => s.page is ScanSettingsAdminTab),
        isTrue,
      );
    });

    test('under document scanning, at its own address', () {
      final section = platformConsoleSections.firstWhere(
        (s) => s.page is ScanSettingsAdminTab,
      );
      expect(section.group, 'Document scanning');
      expect(section.path, '/admin/scan-settings');
      // Not plain 'Settings': the console's sections join the one
      // side menu, where `/settings` already carries that word.
      expect(section.label, 'Scanning settings');
    });
  });
}

OcrSettings _ocr({required bool allowed, bool takesKey = true}) =>
    OcrSettings(
      enabled: true,
      provider: 'gemini',
      keySource: 'platform',
      hasOwnKey: false,
      keys: const {},
      balance: 0,
      price: 0.3,
      ownKeyAllowed: allowed,
      providers: [
        OcrProvider(
          code: 'gemini',
          name: 'Gemini',
          price: 0.3,
          takesKey: takesKey,
          runsOnDevice: false,
          ready: true,
        ),
      ],
    );

class _FakePlatform implements PlatformRepo {
  /// What the last toggle asked for. Null until something moves, which
  /// is the assertion in the case where nothing should.
  Map<String, Object?>? moved;

  @override
  Future<void> setScanSurface({required String key, required bool on}) async {
    moved = {'key': key, 'on': on};
  }

  @override
  Future<Map<String, dynamic>> scanSurfaces() async => const {};

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
        'the scanning switches called PlatformRepo.'
        '${invocation.memberName}, which this fake does not answer',
      );
}

class _FakeRepo implements Repo {
  @override
  Future<List<Map<String, dynamic>>> bankStatementLines(
    String bankAccountId, {
    bool onlyOpen = false,
  }) async =>
      const [];

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
        'the scanning switches called Repo.${invocation.memberName}, '
        'which this fake does not answer',
      );
}
