import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/core/providers.dart';
import 'package:iakauntan/src/core/theme.dart';
import 'package:iakauntan/src/data/models.dart';
import 'package:iakauntan/src/data/repository.dart';
import 'package:iakauntan/src/features/documents/exchange_rates_screen.dart';

/// What rate the ledger would apply, and where it came from.
///
/// The question this screen answers is not "what are rates doing" --
/// nobody runs an accounting system for that. It is "why will this euro
/// invoice not post?", and the answer is the row with nothing in it.
/// Posting refuses a currency it cannot price rather than assuming par,
/// so a missing rate is a hard stop, and the screen exists to show it
/// before month end rather than during it.
///
/// Two things live only in this widget.
///
/// A MISSING RATE HAS TO LOOK MISSING. Rendering a null as 0.0000, or
/// as a dash that reads like a decoration, hides the one row somebody
/// opened the screen for -- and the subtitle has to say what it means,
/// which is that a document in that currency will not post at all.
///
/// AND A TYPED RATE IS NOT A PUBLISHED ONE. They resolve differently:
/// where the two share a date the typed one wins, and a published rate
/// is never written from this app. A row that called somebody's own
/// entry "Bank Negara Malaysia" would be asserting the central bank
/// said something it did not.
void main() {
  Map<String, dynamic> rateRow({
    String currency = 'EUR',
    String name = 'Euro',
    num? rate = 4.85,
    bool isOwn = false,
    String? source = 'bnm',
    String on = '2026-09-14',
  }) => {
    'currency': currency,
    'name': name,
    'rate': rate,
    'is_own': isOwn,
    'source': source,
    'rate_date': on,
  };

  Widget wrap(
    List<Map<String, dynamic>> board, {
    String role = 'owner',
    String base = 'MYR',
  }) => ProviderScope(
    overrides: [
      repoProvider.overrideWithValue(_FakeRepo(board)),
      currentOrgProvider.overrideWith(
        (ref) async => Organization(
          id: 'o1',
          name: 'Rantaian Maju Sdn Bhd',
          slug: 'rantaian',
          baseCurrency: base,
        ),
      ),
      memberRoleProvider.overrideWith((ref) async => role),
    ],
    child: MaterialApp(
      theme: AppTheme.light(),
      home: const ExchangeRatesScreen(),
    ),
  );

  Future<void> show(
    WidgetTester tester,
    List<Map<String, dynamic>> board, {
    String role = 'owner',
    String base = 'MYR',
  }) async {
    await tester.pumpWidget(wrap(board, role: role, base: base));
    await tester.pumpAndSettle();
  }

  group('the row somebody opened the screen for', () {
    testWidgets('a currency with no rate says so, and says what it costs',
        (tester) async {
      await show(tester, [
        rateRow(currency: 'EUR', name: 'Euro', rate: null),
        rateRow(currency: 'SGD', name: 'Singapore Dollar', rate: 3.12),
      ]);

      // Not 0.0000, and not a dash that reads as decoration.
      expect(find.text('no rate'), findsOneWidget);
      expect(find.textContaining('0.0000'), findsNothing);
      expect(find.text('Nothing on file. Enter one, or wait for the feed.'),
          findsOneWidget);

      // And the heading counts it, in the words that matter: the
      // document will not post.
      expect(
        find.textContaining('1 currency has no rate on'),
        findsOneWidget,
      );
      expect(find.textContaining('will not post'), findsOneWidget);
    });

    testWidgets('two missing currencies read as plural, and as "one of them"',
        (tester) async {
      await show(tester, [
        rateRow(currency: 'EUR', rate: null),
        rateRow(currency: 'GBP', name: 'Pound Sterling', rate: null),
        rateRow(currency: 'SGD', name: 'Singapore Dollar', rate: 3.12),
      ]);

      expect(find.textContaining('2 currencies have no rate on'),
          findsOneWidget);
      // "A document in one of them will not post" -- not "in it".
      expect(find.textContaining('A document in one of them'), findsOneWidget);
    });

    testWidgets('and a complete board says so rather than saying nothing',
        (tester) async {
      // The control. Silence where the warning would be is
      // indistinguishable from a warning that failed to render.
      await show(tester, [
        rateRow(currency: 'EUR', rate: 4.85),
        rateRow(currency: 'SGD', name: 'Singapore Dollar', rate: 3.12),
      ]);

      expect(find.textContaining('Every currency has a rate on'),
          findsOneWidget);
      expect(find.text('no rate'), findsNothing);
      expect(find.textContaining('will not post'), findsNothing);
    });
  });

  group('where the rate came from', () {
    testWidgets('a published rate is named as the bank that published it',
        (tester) async {
      await show(tester, [
        rateRow(isOwn: false, source: 'bnm', on: '2026-09-14'),
      ]);

      expect(find.text('Bank Negara Malaysia · 14/09/2026'), findsOneWidget);
      // And is offered as an override, not a change: it is not this
      // company's number to edit.
      expect(find.widgetWithText(TextButton, 'Override'), findsOneWidget);
      expect(find.widgetWithText(TextButton, 'Change'), findsNothing);
    });

    testWidgets('a rate somebody typed says it was entered here',
        (tester) async {
      // The distinction the screen exists to preserve. Calling this
      // "Bank Negara Malaysia" asserts the central bank said something
      // it did not.
      await show(tester, [
        rateRow(isOwn: true, source: 'manual', on: '2026-09-15'),
      ]);

      expect(find.text('Entered here · 15/09/2026'), findsOneWidget);
      expect(find.textContaining('Bank Negara'), findsNothing);
      expect(find.widgetWithText(TextButton, 'Change'), findsOneWidget);
    });

    testWidgets('a published rate from somewhere else is still not ours',
        (tester) async {
      // `source` is not always bnm, and the fallback must not claim a
      // bank that did not supply it.
      await show(tester, [
        rateRow(isOwn: false, source: 'ecb', on: '2026-09-14'),
      ]);

      expect(find.text('Published · 14/09/2026'), findsOneWidget);
      expect(find.textContaining('Bank Negara'), findsNothing);
    });
  });

  group('the rate itself', () {
    testWidgets('reads as one unit of the currency in the base',
        (tester) async {
      await show(tester, [rateRow(currency: 'SGD', rate: 3.4567)]);

      // The direction is the thing: "1 SGD = 3.4567 MYR" and the
      // reciprocal are both plausible-looking and differ by a factor of
      // twelve on a real invoice.
      expect(find.text('1 SGD = 3.4567 MYR'), findsOneWidget);
    });

    testWidgets('keeps the places a thin currency needs', (tester) async {
      // IDR against the ringgit is 0.00027. Two decimal places would
      // render it as 0.00 and price every Indonesian invoice at nothing.
      await show(tester, [
        rateRow(currency: 'IDR', name: 'Rupiah', rate: 0.00027),
      ]);

      expect(find.text('1 IDR = 0.00027 MYR'), findsOneWidget);
    });

    testWidgets('and follows the company base currency, not the ringgit',
        (tester) async {
      // A company keeping books in Singapore dollars sees its own base
      // on every row and in the heading.
      await show(tester, [rateRow(currency: 'MYR', name: 'Ringgit', rate: 0.29)],
          base: 'SGD');

      expect(find.text('1 MYR = 0.29 SGD'), findsOneWidget);
      expect(find.text('One SGD buys'), findsOneWidget);
    });
  });

  group('who may type a rate', () {
    testWidgets('somebody who may write is offered every row',
        (tester) async {
      await show(tester, [
        rateRow(currency: 'EUR', rate: null, isOwn: false),
        rateRow(currency: 'SGD', rate: 3.12, isOwn: true, source: 'manual'),
      ]);

      // One per row, each labelled for what that row is: a published
      // rate is overridden, this company's own is changed.
      expect(find.widgetWithText(TextButton, 'Override'), findsOneWidget);
      expect(find.widgetWithText(TextButton, 'Change'), findsOneWidget);
      // Two, not three. The app bar's date picker is a
      // `TextButton.icon`, which is a private subclass and so is NOT
      // matched by `byType` at all.
      expect(find.byType(TextButton), findsNWidgets(2));
    });

    testWidgets('a viewer is offered none', (tester) async {
      // Typing a rate changes what every document in that currency
      // posts at. A viewer must not.
      await show(tester, [
        rateRow(currency: 'EUR', rate: null),
        rateRow(currency: 'SGD', rate: 3.12),
      ], role: 'viewer');

      expect(find.widgetWithText(TextButton, 'Override'), findsNothing);
      expect(find.widgetWithText(TextButton, 'Change'), findsNothing);
      // The board is still readable: this withholds the button, not the
      // rates. Both rows are there, each with what it actually says.
      expect(find.text('1 SGD = 3.12 MYR'), findsOneWidget);
      expect(find.text('no rate'), findsOneWidget);
      expect(find.byType(TextButton), findsNothing);
    });
  });

  group('which rate the ledger uses', () {
    testWidgets('is said on the screen rather than left to be worked out',
        (tester) async {
      await show(tester, [rateRow()]);

      expect(find.text('Which rate the ledger uses'), findsOneWidget);
      // The resolution rule, the tie-break, and the fact that a
      // published rate is never altered here -- all three, because two
      // rows that disagree are otherwise a support call.
      expect(find.textContaining('most recent rate on or before the document '
          'date'), findsOneWidget);
      expect(find.textContaining('yours is used'), findsOneWidget);
      expect(find.textContaining('never altered by anything in this app'),
          findsOneWidget);
    });
  });
}

/// Only the one method the screen calls. Everything else on `Repo`
/// throws rather than returning null quietly: a screen that grew a
/// second call should fail here loudly rather than rendering an empty
/// board that looks like a company with no currencies.
class _FakeRepo implements Repo {
  _FakeRepo(this.board);

  final List<Map<String, dynamic>> board;

  @override
  Future<List<Map<String, dynamic>>> exchangeRateBoard([DateTime? onDate]) async =>
      board;

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
        'the exchange rates screen called Repo.'
        '${invocation.memberName}, which this fake does not answer',
      );
}
