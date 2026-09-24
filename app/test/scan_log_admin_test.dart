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
    Widget harness(
      List<ScanLogEntry> rows,
      ScanHealth health, {
      List<ReaderFault> faults = const [],
    }) =>
        ProviderScope(
      overrides: [
        scanLogProvider.overrideWith((ref, q) async => rows),
        scanHealthProvider.overrideWith((ref) async => health),
        readerFailuresProvider.overrideWith((ref) async => faults),
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

  /// A fault row off the wire. `0685`.
  ///
  /// The screen tests build `ReaderFault` directly, so nothing was
  /// reading `fromJson` — and a mutation run proved it: swapping `read`
  /// and `failed` on the way in passed every test while inverting the
  /// single claim the section is for. A reader that had never worked
  /// would have read "47 read · 0 failed" and no verdict.
  group('reading a fault off the wire', () {
    Map<String, dynamic> row({
      Object? read = 0,
      Object? failed = 47,
    }) =>
        {
          'provider': 'gemini',
          'provider_name': 'Gemini',
          'read': read,
          'failed': failed,
          'fault': 'invalid json payload received. unknown name "strict"',
          'n': 47,
          'first_seen': '2026-09-01T10:00:00Z',
          'last_seen': '2026-09-22T10:00:00Z',
          'example_ref': 'aaaa1111',
        };

    test('a row arrives whole', () {
      final f = ReaderFault.fromJson(row());

      expect(f.provider, 'gemini');
      expect(f.providerName, 'Gemini');
      // The two that decide what the screen says. Swapped, a reader
      // that has never worked reads as one that never fails.
      expect(f.read, 0);
      expect(f.failed, 47);
      // And the message, which is the actionable part — "unknown name
      // strict" is the fix, not the symptom.
      expect(f.fault, contains('unknown name'));
      expect(f.fault, contains('strict'));
      expect(f.n, 47);
      expect(f.exampleRef, 'aaaa1111');
      expect(f.firstSeen, isNotNull);
      expect(f.lastSeen, isNotNull);
    });

    test('and the verdict follows the counts, not the other way round', () {
      expect(ReaderFault.fromJson(row(read: 0, failed: 47)).neverWorked,
          isTrue);
      expect(ReaderFault.fromJson(row(read: 300, failed: 1)).neverWorked,
          isFalse);
      // Nothing has happened at all, which is not the same as never
      // working and must not be dressed as it.
      expect(ReaderFault.fromJson(row(read: 0, failed: 0)).neverWorked,
          isFalse);
    });

    test('a count that arrives as a string is still a count', () {
      // PostgREST returns bigint as a JSON number, but a `count(*)`
      // has come back as a string from this stack before and a reader
      // silently scoring zero is the failure that would cause.
      final f = ReaderFault.fromJson(row(read: '3', failed: '2'));
      expect(f.read, 3);
      expect(f.failed, 2);
    });
  });

  /// What each reader keeps saying. `0685`.
  ///
  /// The log below this answers "what happened to THIS scan", which is
  /// what somebody asks when they are holding a reference. It cannot
  /// answer the other question — fifty rows at a time, no grouping, no
  /// provider filter — so a reader that has failed on every scan since
  /// the day it was switched on looks exactly like one that failed
  /// twice last Tuesday.
  ///
  /// The row that matters is the one where `read` is zero. `0679`'s
  /// fallback hides it: the scan quietly goes to another reader, the
  /// tenant gets their document, the platform pays twice, and nobody
  /// is told.
  group('what the readers keep saying', () {
    Widget harness(List<ReaderFault> faults) => ProviderScope(
          overrides: [
            scanLogProvider.overrideWith((ref, q) async => const []),
            scanHealthProvider.overrideWith((ref) async => ScanHealth.none),
            readerFailuresProvider.overrideWith((ref) async => faults),
          ],
          child: MaterialApp(
            theme: AppTheme.light(),
            home: const Scaffold(body: ScanLogAdminTab()),
          ),
        );

    ReaderFault fault({
      String provider = 'gemini',
      String name = 'Gemini',
      int read = 0,
      int failed = 47,
      String message = 'invalid json payload received. unknown name '
          '"strict" at \'response_format.json_schema\': cannot find field.',
      int n = 47,
      String? ref = 'aaaa1111',
    }) =>
        ReaderFault(
          provider: provider,
          providerName: name,
          read: read,
          failed: failed,
          fault: message,
          n: n,
          exampleRef: ref,
        );

    Future<void> show(WidgetTester tester, List<ReaderFault> faults) async {
      tester.view.physicalSize = const Size(1200, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(harness(faults));
      await tester.pumpAndSettle();
    }

    testWidgets('the vendor\'s own words are on the screen', (tester) async {
      // The whole reason this section exists. A grouped count with the
      // message left off would say a reader is failing and not what to
      // do about it, and "unknown name strict" is the fix.
      await show(tester, [fault()]);

      expect(find.textContaining('unknown name'), findsOneWidget);
      expect(find.textContaining('strict'), findsOneWidget);
    });

    testWidgets('a reader that has never worked says so', (tester) async {
      await show(tester, [fault(read: 0, failed: 47)]);

      expect(find.text('never worked'), findsOneWidget);
      // Beside the two numbers that make it a fact rather than a
      // label. Without them this is 47 unremarkable failures.
      expect(find.text('0 read · 47 failed'), findsOneWidget);
      expect(find.text('×47'), findsOneWidget);
    });

    testWidgets('and a reader that mostly works does not', (tester) async {
      // The claim that would otherwise be decoration on every row. A
      // reader with one bad day is not a reader to go and switch off.
      await show(tester,
          [fault(provider: 'claude', name: 'Claude', read: 300, failed: 1, n: 1)]);

      expect(find.text('never worked'), findsNothing);
      expect(find.text('300 read · 1 failed'), findsOneWidget);
    });

    testWidgets('a reference is offered so the whole row can be found',
        (tester) async {
      await show(tester, [fault(ref: 'aaaa1111')]);
      expect(find.textContaining('aaaa1111'), findsOneWidget);
    });

    testWidgets('and nothing is drawn when no reader has failed',
        (tester) async {
      // The ordinary case. A heading over an empty list is a page
      // saying something is wrong when nothing is.
      await show(tester, const []);

      expect(find.text('What the readers keep saying'), findsNothing);
      expect(find.text('never worked'), findsNothing);
    });
  });

  // The row as the database hands it over. Built by hand everywhere
  // else in this file, so without these the parsing had no test at all
  // -- and a mutant that dropped the body on the way out survived the
  // first sweep without a single assertion noticing.
  group('one call, as it arrives', () {
    test('every field comes across', () {
      final e = ScanExchange.fromJson({
        'id': 'ex-1',
        'at': '2026-09-24T03:22:00+00:00',
        'attempt': 2,
        'provider': 'gemini',
        'endpoint': 'https://generativelanguage.googleapis.com/v1beta',
        'http_status': 503,
        'ms': 812,
        'ok': false,
        'body': '{"error":{"message":"high demand"}}',
        'truncated': true,
      });

      expect(e.attempt, 2);
      expect(e.provider, 'gemini');
      expect(e.httpStatus, 503);
      expect(e.ms, 812);
      expect(e.ok, isFalse);
      expect(e.truncated, isTrue);
      expect(e.body, contains('high demand'));
      expect(e.noAnswer, isFalse);
    });

    // The case the console draws differently, and the one the column
    // cannot express except as absence: nothing answered at all. Null
    // and zero are the same answer here, and a check written `== 0`
    // alone would call a null row an answer.
    test('a status that is absent is no answer, and so is zero', () {
      expect(
        ScanExchange.fromJson({
          'id': 'a',
          'at': '2026-09-24T03:22:00+00:00',
          'attempt': 1,
          'http_status': null,
          'body': 'TypeError: error sending request',
        }).noAnswer,
        isTrue,
      );
      expect(
        ScanExchange.fromJson({
          'id': 'b',
          'at': '2026-09-24T03:22:00+00:00',
          'attempt': 1,
          'http_status': 0,
        }).noAnswer,
        isTrue,
      );
    });

    test('and a reply that was not cut says so', () {
      final e = ScanExchange.fromJson({
        'id': 'c',
        'at': '2026-09-24T03:22:00+00:00',
        'attempt': 1,
        'http_status': 200,
        'ok': true,
        'body': '{"content":[]}',
        'truncated': false,
      });
      expect(e.truncated, isFalse);
      expect(e.ok, isTrue);
      expect(e.body, '{"content":[]}');
    });
  });

  // ------------------------------------------------------------------
  // What the reader actually said
  //
  // `0704`. Asked for from the console: "all error or reply by models
  // should be logged in raw as this is to be used for troubleshooting".
  // What the row above carries is `ocr_scans.error` -- ONE SENTENCE,
  // written by us out of whichever field of the vendor's JSON the edge
  // function reached for. The day a reader answers something the code
  // did not anticipate, that sentence is `HTTP 400` and the body that
  // would have explained it is gone.
  // ------------------------------------------------------------------
  group('the raw replies', () {
    ScanExchange call({
      String id = 'ex-1',
      int attempt = 1,
      String? provider = 'gemini',
      String? endpoint = 'https://generativelanguage.googleapis.com/v1beta',
      int? httpStatus = 503,
      int? ms = 812,
      bool ok = false,
      bool truncated = false,
      String? body =
          '{"error":{"message":"This model is currently experiencing high '
          'demand."}}',
    }) =>
        ScanExchange(
          id: id,
          at: DateTime(2026, 9, 24, 11, 22),
          attempt: attempt,
          ok: ok,
          truncated: truncated,
          provider: provider,
          endpoint: endpoint,
          httpStatus: httpStatus,
          ms: ms,
          body: body,
        );

    Future<void> open(WidgetTester tester, List<ScanExchange> calls) async {
      tester.view.physicalSize = const Size(1200, 2200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(ProviderScope(
        overrides: [
          scanLogProvider.overrideWith((ref, q) async => [scan()]),
          scanHealthProvider.overrideWith((ref) async => ScanHealth.none),
          readerFailuresProvider.overrideWith((ref) async => const []),
          scanExchangesProvider.overrideWith((ref, id) async => calls),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const Scaffold(body: ScanLogAdminTab()),
        ),
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(ExpansionTile));
      await tester.pumpAndSettle();
    }

    testWidgets('the vendor own words, verbatim', (tester) async {
      await open(tester, [call()]);

      expect(
        find.textContaining('This model is currently experiencing high demand'),
        findsOneWidget,
      );
      expect(find.textContaining('HTTP 503'), findsOneWidget);
      expect(find.textContaining('812 ms'), findsOneWidget);
    });

    // One scan can be three requests to two vendors -- the attempt,
    // `459d3716`'s retry and `0679`'s fallback -- and which of them said
    // what was the unanswerable question.
    testWidgets('every call, in the order they happened', (tester) async {
      await open(tester, [
        call(id: 'a', attempt: 1),
        call(id: 'b', attempt: 2),
        call(
          id: 'c',
          attempt: 3,
          provider: 'claude',
          httpStatus: 200,
          ok: true,
          body: '{"content":[{"type":"text","text":"99 Speedmart"}]}',
        ),
      ]);

      expect(find.text('#1'), findsOneWidget);
      expect(find.text('#3'), findsOneWidget);
      expect(find.text('claude'), findsOneWidget);
      // The successful one is kept too, which is the half somebody
      // would be tempted to drop: a reading that came back WRONG is
      // where the raw reply matters most, and it did not fail.
      expect(find.textContaining('99 Speedmart'), findsOneWidget);
    });

    // Zero is not a status. It is what a status reads as when nothing
    // answered at all, which is a different fault from being refused.
    testWidgets('nothing answering is not drawn as HTTP 0', (tester) async {
      await open(tester, [
        call(httpStatus: 0, body: 'TypeError: error sending request'),
      ]);

      expect(find.text('no answer'), findsOneWidget);
      expect(find.textContaining('HTTP 0'), findsNothing);
      expect(find.textContaining('error sending request'), findsOneWidget);
    });

    testWidgets('a cut reply says it was cut', (tester) async {
      await open(tester, [call(truncated: true)]);
      expect(find.textContaining('Cut at 16k'), findsOneWidget);
    });

    // Two different nothings, and a screen that said only "no replies"
    // would leave somebody looking for a bug in the logging.
    testWidgets('and nothing kept says which nothing it is', (tester) async {
      await open(tester, const []);

      expect(find.textContaining('never reached a reader'), findsOneWidget);
      expect(
        find.textContaining('before replies were being kept'),
        findsOneWidget,
      );
    });
  });
}
