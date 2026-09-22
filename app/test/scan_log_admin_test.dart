import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/core/providers.dart';
import 'package:iakauntan/src/core/theme.dart';
import 'package:iakauntan/src/core/widgets.dart';
import 'package:iakauntan/src/data/ocr_repository.dart';
import 'package:iakauntan/src/features/admin/platform_console_screen.dart';
import 'package:iakauntan/src/features/admin/scan_log_admin.dart';

/// The console page that makes a failure reference mean something.
///
/// A scan that fails shows the person scanning a generic sentence and
/// two uuids. That vagueness is right and stays — a vendor's message
/// quotes the project and the processor — but until `0680` nothing in
/// the app read `ocr_scans` at all, so the reference had nowhere to be
/// quoted and "get in touch" meant hand-written SQL against
/// production.
///
/// Two claims here are worth more than the rest:
///
///   * the vendor's sentence is ON THE SCREEN. That is the entire
///     reason the page exists, and a page that listed scans without it
///     would look finished and answer nothing.
///
///   * a scan stuck `pending` is drawn as a PROBLEM. It does not look
///     like one — the status reads as "still going" for ever — and the
///     charge behind it was taken and never refunded.
void main() {
  ScanLogEntry scan({
    String id = '6e50da40-7693-48c5-8b6d-f062e9f7441b',
    String? logRef,
    String org = 'Sinar Teknologi',
    String provider = 'Claude',
    String keySource = 'platform',
    String status = 'failed',
    double charged = 0.30,
    bool refunded = false,
    String? fellBackTo,
    String? fileName = 'bil-september.jpg',
    String? error = 'Anthropic returned 401: invalid x-api-key',
    Duration age = const Duration(minutes: 10),
  }) => ScanLogEntry(
    id: id,
    logRef: logRef,
    createdAt: DateTime.now().subtract(age),
    orgName: org,
    providerName: provider,
    keySource: keySource,
    status: status,
    charged: charged,
    refunded: refunded,
    fellBackTo: fellBackTo,
    fileName: fileName,
    error: error,
  );

  group('a scan that never settled', () {
    // The status says `pending`, which reads as "still going" for
    // ever. An hour on it means the function died between `ocr_begin`
    // and `ocr_finish`, so the charge was taken and the refund never
    // ran.
    test('an old pending scan is stuck, not in progress', () {
      expect(
        scan(status: 'pending', age: const Duration(hours: 3)).unsettled,
        isTrue,
      );
    });

    test('a scan that started a minute ago is simply running', () {
      final fresh = scan(status: 'pending', age: const Duration(minutes: 1));
      expect(fresh.unsettled, isFalse);
      // And is not money owed either — nothing has gone wrong yet.
      expect(fresh.owed, isFalse);
    });

    test('a scan that succeeded is never stuck, however old', () {
      expect(
        scan(status: 'ok', age: const Duration(days: 30)).unsettled,
        isFalse,
      );
    });
  });

  group('money that was taken and not given back', () {
    test('a failed charged scan that was not refunded is owed', () {
      expect(scan().owed, isTrue);
    });

    test('a refunded one is not', () {
      expect(scan(refunded: true).owed, isFalse);
    });

    // A company on its own key is charged nothing, so `refunded` being
    // false is the ordinary case and not a debt. Without this the
    // screen would cry "not refunded" on every scan a company ran on
    // its own key.
    test('a free scan is not owed however it ended', () {
      expect(scan(charged: 0).owed, isFalse);
      expect(scan(charged: 0, keySource: 'own').owed, isFalse);
    });

    test('a scan that succeeded is not owed', () {
      expect(scan(status: 'ok').owed, isFalse);
    });
  });

  group('reading the log off the wire', () {
    test('a row arrives whole', () {
      final e = ScanLogEntry.fromJson(const {
        'id': '6e50da40-7693-48c5-8b6d-f062e9f7441b',
        'log_ref': 'e5b6506c-856f-4a76-b62f-d58504065d3e',
        'created_at': '2026-09-22T08:40:00Z',
        'org_name': 'Sinar Teknologi',
        'provider': 'claude',
        'provider_name': 'Claude',
        'key_source': 'platform',
        'status': 'failed',
        'amount_charged': 0.3,
        'refunded': false,
        'file_name': 'bil-september.jpg',
        'error': 'Anthropic returned 401',
      });
      expect(e.logRef, 'e5b6506c-856f-4a76-b62f-d58504065d3e');
      expect(e.error, 'Anthropic returned 401');
      expect(e.charged, 0.3);
      expect(e.owed, isTrue);
    });

    // An empty string is not an error. A scan that succeeded has
    // nothing in that column, and a row that read '' as a message
    // would draw an empty red line under every successful scan.
    test('a blank error is no error', () {
      expect(
        ScanLogEntry.fromJson(const {'id': 'x', 'error': '   '}).error,
        isNull,
      );
    });

    test('a company since deleted still names something', () {
      expect(
        ScanLogEntry.fromJson(const {'id': 'x'}).orgName,
        'a company since deleted',
      );
    });
  });

  group('the numbers above the list', () {
    test('they arrive', () {
      final h = ScanHealth.fromJson(const {
        'ok_24h': 12,
        'failed_24h': 3,
        'unsettled': 2,
        'unsettled_charged': 0.6,
      });
      expect(h.ok24h, 12);
      expect(h.failed24h, 3);
      expect(h.unsettled, 2);
      expect(h.unsettledCharged, 0.6);
    });

    // A caller who is not a platform administrator gets `{}` rather
    // than an exception, so the screen has to draw zeroes instead of
    // throwing.
    test('an empty answer is zeroes, not a crash', () {
      final h = ScanHealth.fromJson(const {});
      expect(h.ok24h, 0);
      expect(h.unsettled, 0);
    });
  });

  group('the page', () {
    Widget harness(List<ScanLogEntry> rows, ScanHealth health) => ProviderScope(
      overrides: [
        scanLogProvider.overrideWith((ref, q) async => rows),
        scanHealthProvider.overrideWith((ref) async => health),
      ],
      child: MaterialApp(
        theme: AppTheme.light(),
        home: const Scaffold(body: ScanLogAdminTab()),
      ),
    );

    testWidgets('shows the reason, which is why it exists', (tester) async {
      tester.view.physicalSize = const Size(1200, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(harness([scan()], ScanHealth.none));
      await tester.pumpAndSettle();

      expect(
        find.text('Anthropic returned 401: invalid x-api-key'),
        findsOneWidget,
      );
      expect(find.text('Sinar Teknologi'), findsOneWidget);
      // And whose key ran it, which decides whose problem it is.
      expect(find.textContaining("the platform's key"), findsOneWidget);
      expect(find.textContaining('bil-september.jpg'), findsOneWidget);
    });

    testWidgets('says on the row when money did not come back', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1200, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(harness([scan()], ScanHealth.none));
      await tester.pumpAndSettle();

      expect(find.textContaining('not refunded'), findsOneWidget);
    });

    testWidgets('a company on its own key is not accused of being owed', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1200, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        harness([scan(charged: 0, keySource: 'own')], ScanHealth.none),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('not refunded'), findsNothing);
      expect(find.textContaining('their own key'), findsOneWidget);
    });

    testWidgets('a stuck scan is drawn as stuck, not as pending', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1200, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        harness([
          scan(status: 'pending', age: const Duration(hours: 3), error: null),
        ], ScanHealth.none),
      );
      await tester.pumpAndSettle();

      // Scoped to the chip: the stat above the list carries the same
      // two words as its own label, so a bare `find.text` answers a
      // different question. `StatusChip` runs its word through
      // `Fmt.label`, so what is on screen is capitalised.
      final chip = find.descendant(
        of: find.byType(StatusChip),
        matching: find.text('Never settled'),
      );
      expect(chip, findsOneWidget);
      // Scoped for the second time and for a second reason: `Pending`
      // is also one of the four status filters, and is on screen
      // whatever the list holds.
      expect(
        find.descendant(
          of: find.byType(StatusChip),
          matching: find.text('Pending'),
        ),
        findsNothing,
      );
    });

    testWidgets('the unsettled count names what it cost', (tester) async {
      tester.view.physicalSize = const Size(1200, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        harness([], const ScanHealth(
          ok24h: 12,
          failed24h: 3,
          unsettled: 2,
          unsettledCharged: 0.60,
        )),
      );
      await tester.pumpAndSettle();

      expect(
        find.textContaining('taken and not refunded'),
        findsOneWidget,
      );
      expect(find.textContaining('RM 0.60'), findsOneWidget);
    });

    testWidgets('the search takes either identifier off the message', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1200, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(harness([scan()], ScanHealth.none));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('scan-log-search')), findsOneWidget);
      // Said, because the message somebody is quoting from carries two
      // uuids and calls only one of them a reference.
      expect(find.textContaining('Either one off the message'), findsOneWidget);

      // Searching drops the status filter: somebody who has pasted a
      // reference wants THAT scan, whatever state it is in.
      expect(find.byKey(const ValueKey('scan-log-status')), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('scan-log-search')),
        'e5b6506c',
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('scan-log-status')), findsNothing);
      expect(find.textContaining('Showing every status'), findsOneWidget);
    });

    testWidgets('an empty search says the old failures lack a reference', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1200, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(harness([], ScanHealth.none));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const ValueKey('scan-log-search')),
        'e5b6506c',
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      // The one thing somebody searching in vain needs to know: a
      // failure from before 0680 was never given a stored reference,
      // so only its scan id will find it.
      expect(find.textContaining('before the reference was stored'),
          findsOneWidget);
    });
  });

  test('the page is reachable from the console', () {
    final section = platformConsoleSections
        .where((s) => s.path == '/admin/scan-log')
        .toList();
    expect(section, hasLength(1));
    expect(section.single.page, isA<ScanLogAdminTab>());
    expect(section.single.group, 'Document scanning');
    // Not the glyph the platform's own trail already uses — two rows
    // in one menu with one icon is two rows nobody tells apart.
    final trail = platformConsoleSections
        .firstWhere((s) => s.path == '/admin/trail');
    expect(section.single.icon, isNot(trail.icon));
  });
}
