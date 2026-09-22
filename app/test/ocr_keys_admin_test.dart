import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/core/providers.dart';
import 'package:iakauntan/src/core/theme.dart';
import 'package:iakauntan/src/data/ocr_repository.dart';
import 'package:iakauntan/src/features/admin/ocr_keys_admin.dart';
import 'package:iakauntan/src/features/admin/platform_console_screen.dart';

/// The console page for a reader's pool of keys. `0675`.
///
/// The claim that matters most is negative and is asserted twice: this
/// page CANNOT show a key. `ocr_keys_for` has no column that could
/// carry one, so there is nothing to leak — but a page that started
/// carrying one would leak it to every platform operator's screen and
/// browser history, and nothing about the page would look different.
///
/// The rest is derived text, and it is derived text somebody reads at
/// the moment scanning has stopped:
///
///   * a key with no caps says "No cap" rather than printing three
///     lines of nothing;
///   * a key with no clock says "Any time" rather than a blank, because
///     the difference between "always" and "this failed to load" is the
///     difference between leaving it alone and going to look for a bug;
///   * and a key that is standing down says WHICH of the three reasons,
///     because they are three different things to do: reverse a
///     decision, wait until six, or wait for nobody.
OcrPoolKey key({
  String id = 'k1',
  String label = 'Studio one',
  String tail = '4242',
  bool active = true,
  bool inWindow = true,
  bool headroom = true,
  int spentMinute = 0,
  int spentDay = 0,
  int spentMonth = 0,
  int? perMinute,
  int? perDay,
  int? perMonth,
  List<int> hours = const [],
  List<int> weekdays = const [],
  List<int> months = const [],
  String? lastError,
}) =>
    OcrPoolKey(
      id: id,
      label: label,
      keyTail: tail,
      isActive: active,
      inWindow: inWindow,
      hasHeadroom: headroom,
      spentMinute: spentMinute,
      spentDay: spentDay,
      spentMonth: spentMonth,
      perMinute: perMinute,
      perDay: perDay,
      perMonth: perMonth,
      hours: hours,
      weekdays: weekdays,
      months: months,
      lastError: lastError,
    );

void main() {
  group('reading a key off the wire', () {
    // Every test below this group builds an `OcrPoolKey` directly,
    // which asserts nothing about the row PostgREST actually sends. A
    // mutation run said so: the fallback in the array reader could be
    // changed to hand back a list with a value in it and nothing
    // noticed -- and that fallback is what an absent clock arrives as.

    test('a full row reads as itself', () {
      final k = OcrPoolKey.fromJson(const {
        'id': 'k1',
        'label': 'Studio one',
        'key_tail': '4242',
        'is_active': true,
        'in_window': true,
        'has_headroom': false,
        'spent_minute': 15,
        'spent_day': 233,
        'spent_month': 4011,
        'per_minute': 15,
        'per_day': 1500,
        'per_month': null,
        'hours': [9, 10, 11],
        'weekdays': [1, 2, 3, 4, 5],
        'months': <int>[],
        'last_used_at': '2026-09-22T05:31:00Z',
        'last_error': '  ',
        'last_error_at': null,
      });

      expect(k.label, 'Studio one');
      expect(k.keyTail, '4242');
      expect(k.hasHeadroom, isFalse);
      expect(k.standDownReason, 'Spent for now');
      expect(k.perMonth, isNull, reason: 'a cap nobody set is not nought');
      expect(k.hours, [9, 10, 11]);
      expect(k.months, isEmpty);
      // Whitespace is not an error message. A row carrying one would
      // draw an empty red line under the key.
      expect(k.lastError, isNull);
      expect(k.lastUsedAt, isNotNull);
    });

    test('an absent clock is empty, not a list with something in it', () {
      // The column is `not null default '{}'`, so this is what a key
      // with no clock genuinely arrives as -- and a reader that turned
      // it into `[0]` would stand every key down outside midnight.
      final k = OcrPoolKey.fromJson(const {
        'id': 'k1',
        'label': 'One',
        'key_tail': '0000',
        'is_active': true,
        'in_window': true,
        'has_headroom': true,
        'hours': <int>[],
        'weekdays': <int>[],
        'months': <int>[],
      });
      expect(k.hours, isEmpty);
      expect(k.weekdays, isEmpty);
      expect(k.months, isEmpty);
      expect(keyClockLine(k), 'Any time');
    });

    test('and a missing one is too, rather than throwing', () {
      // Not a shape the function returns -- but a row that lost a
      // column to a later migration must draw rather than take the
      // console down.
      final k = OcrPoolKey.fromJson(const {
        'id': 'k1',
        'label': 'One',
        'key_tail': '0000',
        'is_active': true,
        'in_window': true,
        'has_headroom': true,
      });
      expect(k.hours, isEmpty);
      expect(keyClockLine(k), 'Any time');
      expect(keyBudgetLine(k), 'No cap');
      expect(k.spentDay, 0);
    });

    test('counts and caps survive arriving as strings', () {
      // `numeric` and `bigint` come back from PostgREST as strings often
      // enough that every other model in this app guards against it.
      final k = OcrPoolKey.fromJson(const {
        'id': 'k1',
        'label': 'One',
        'key_tail': '0000',
        'is_active': true,
        'in_window': true,
        'has_headroom': true,
        'per_day': '1500',
        'spent_day': '233',
        'hours': ['9', '17'],
      });
      expect(k.perDay, 1500);
      expect(k.spentDay, 233);
      expect(k.hours, [9, 17]);
      expect(keyBudgetLine(k), '233/1500 a day');
    });
  });

  group('what a key has spent', () {
    test('a key with no caps says so in one word', () {
      expect(keyBudgetLine(key()), 'No cap');
    });

    test('and one with caps shows each against what it may', () {
      expect(
        keyBudgetLine(key(
          perMinute: 15,
          perDay: 1500,
          spentMinute: 4,
          spentDay: 233,
        )),
        '4/15 a minute · 233/1500 a day',
      );
    });

    test('a cap that was not set is not printed', () {
      // The free Google AI Studio tier caps the minute and the day and
      // says nothing about the month. Printing "0/null a month" would
      // be printing a cap nobody set.
      final line = keyBudgetLine(key(perMinute: 15, spentMinute: 15));
      expect(line, '15/15 a minute');
      expect(line.contains('month'), isFalse);
      expect(line.contains('day'), isFalse);
    });

    test('a month-only cap is shown on its own', () {
      expect(
        keyBudgetLine(key(perMonth: 20000, spentMonth: 118)),
        '118/20000 a month',
      );
    });
  });

  group('when a key may run', () {
    test('nothing set is always, and says so', () {
      // Not a blank. A blank reads as a setting that failed to load.
      expect(keyClockLine(key()), 'Any time');
    });

    test('hours are padded and sorted, not shown as they were pressed', () {
      // The array comes back in whatever order the chips were tapped,
      // and "22:00, 09:00" reads as a mistake.
      expect(keyClockLine(key(hours: [22, 9, 13])), '09:00, 13:00, 22:00');
    });

    test('days read as days and months as months', () {
      expect(
        keyClockLine(key(weekdays: [1, 5], months: [1, 12])),
        'Mon, Fri · Jan, Dec',
      );
    });

    test('all three run together in one line', () {
      expect(
        keyClockLine(key(hours: [9], weekdays: [6, 7], months: [3])),
        '09:00 · Sat, Sun · Mar',
      );
    });
  });

  group('why a key is standing down', () {
    test('a key that can run says nothing', () {
      expect(key().standDownReason, isNull);
      expect(key().isUsableNow, isTrue);
    });

    test('switched off comes first, because it is the one to reverse', () {
      // A key that is switched off AND out of hours AND spent is
      // reported as switched off: that is the one a person can do
      // something about, and the other two are consequences of nobody
      // having used it.
      final k = key(active: false, inWindow: false, headroom: false);
      expect(k.standDownReason, 'Switched off');
      expect(k.isUsableNow, isFalse);
    });

    test('out of hours is a wait with a known end', () {
      expect(key(inWindow: false).standDownReason, 'Outside its hours');
    });

    test('spent is a wait that needs nobody', () {
      expect(key(headroom: false).standDownReason, 'Spent for now');
    });

    test('and the three are never confused with one another', () {
      // Each reason must be reachable on its own, or a screen showing
      // one of them is showing it for the wrong reason.
      expect(key(active: false).standDownReason, 'Switched off');
      expect(key(inWindow: false).standDownReason, 'Outside its hours');
      expect(key(headroom: false).standDownReason, 'Spent for now');
    });
  });

  group('what the form refuses', () {
    test('a key with no name cannot be saved', () {
      expect(
        readerKeyProblem(label: '  ', apiKey: 'AIza-x', isNew: true),
        contains('Give the key a name'),
      );
    });

    test('a new key must carry a key, and is told why', () {
      // "Required" would not explain why it cannot be filled in later.
      final problem = readerKeyProblem(label: 'One', apiKey: '', isNew: true);
      expect(problem, contains('Paste the key'));
      expect(problem, contains('cannot be read back'));
    });

    test('an EXISTING key does not have to be retyped', () {
      // The whole point of the asymmetry: this app cannot show anybody
      // the secret it holds, so a cap that could only be raised by
      // retyping the key could not be raised at all.
      expect(
        readerKeyProblem(label: 'One', apiKey: '', isNew: false),
        isNull,
      );
    });

    test('a cap of nought is refused, and a blank one is not', () {
      expect(
        readerKeyProblem(
            label: 'One', apiKey: '', isNew: false, perMinute: '0'),
        contains('above nought'),
      );
      expect(
        readerKeyProblem(
            label: 'One', apiKey: '', isNew: false, perMinute: ''),
        isNull,
      );
    });

    test('and the refusal names the cap that is wrong', () {
      // Three boxes on one line; "a cap is wrong" would leave somebody
      // checking all three.
      expect(
        readerKeyProblem(label: 'One', apiKey: '', isNew: false, perDay: '-5'),
        contains('per a day'),
      );
      expect(
        readerKeyProblem(
            label: 'One', apiKey: '', isNew: false, perMonth: 'lots'),
        contains('per a month'),
      );
    });

    test('a whole good form is accepted', () {
      expect(
        readerKeyProblem(
          label: 'Studio one',
          apiKey: 'AIza-something',
          isNew: true,
          perMinute: '15',
          perDay: '1500',
        ),
        isNull,
      );
    });
  });

  group('the page itself', () {
    Widget harness(List<Map<String, dynamic>> readers, List<OcrPoolKey> pool) =>
        ProviderScope(
          overrides: [
            ocrProviderCatalogProvider.overrideWith((ref) async => readers),
            ocrKeyPoolProvider.overrideWith((ref, args) async => pool),
          ],
          child: MaterialApp(
            theme: AppTheme.light(),
            home: const Scaffold(body: OcrKeysAdminTab()),
          ),
        );

    const gemini = {
      'code': 'gemini',
      'name': 'Gemini',
      'kind': 'openai',
      'takes_key': true,
      'is_active': true,
    };

    testWidgets('lists the pool, and never the key', (tester) async {
      tester.view.physicalSize = const Size(1200, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(harness([gemini], [
        key(label: 'Studio one', tail: '4242', perMinute: 15, spentMinute: 4),
        key(id: 'k2', label: 'Studio two', tail: '9137', headroom: false),
      ]));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text('Studio one'), findsOneWidget);
      expect(find.text('…4242'), findsOneWidget);
      expect(find.textContaining('4/15 a minute'), findsOneWidget);

      // One of the two is spent, so the count says what can run rather
      // than what exists.
      expect(find.text('1 of 2 usable right now'), findsOneWidget);
      expect(find.textContaining('Spent for now'), findsOneWidget);
    });

    testWidgets('an empty pool says what happens without one', (tester) async {
      tester.view.physicalSize = const Size(1200, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(harness([gemini], const []));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text('No keys yet'), findsOneWidget);
      expect(
        find.textContaining('falls back on the key in the'),
        findsOneWidget,
      );
    });

    testWidgets('a reader switched off says the pool is not the problem',
        (tester) async {
      // Somebody filling a pool to fix a stopped scanner needs to know
      // the reader itself is off, or they will fill it and nothing will
      // change.
      tester.view.physicalSize = const Size(1200, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(harness([
        {...gemini, 'is_active': false},
      ], [key()]));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(
        find.textContaining('is switched off in the catalog'),
        findsOneWidget,
      );
      expect(
        find.textContaining('The Readers screen is where it is turned on'),
        findsOneWidget,
      );
    });

    testWidgets('a reader that takes no key is not offered a pool',
        (tester) async {
      // The on-device reader has no key for anybody to bring, and
      // offering to configure one would be offering to configure
      // something that does not exist.
      tester.view.physicalSize = const Size(1200, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(harness([
        const {
          'code': 'mlkit',
          'name': 'On this device',
          'kind': 'device',
          'takes_key': false,
          'is_active': true,
        },
      ], const []));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text('No reader takes a key'), findsOneWidget);
      expect(find.text('On this device'), findsNothing);
    });
  });

  group('reachable from the console', () {
    test('the page is on the menu', () {
      // A console page nothing routes to is a page nobody finds, and
      // that failure is silent.
      expect(
        platformConsoleSections.any((s) => s.page is OcrKeysAdminTab),
        isTrue,
      );
    });

    test('and sits with the rest of the scanning pages', () {
      final section = platformConsoleSections
          .firstWhere((s) => s.page is OcrKeysAdminTab);
      expect(section.group, 'Document scanning');
      expect(section.path, '/admin/reader-keys');
    });
  });
}
