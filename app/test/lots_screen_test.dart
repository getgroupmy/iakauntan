import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/core/providers.dart';
import 'package:iakauntan/src/core/theme.dart';
import 'package:iakauntan/src/data/repository.dart';
import 'package:iakauntan/src/features/stock/lots_screen.dart';

/// Batches and serials: what is on hand, what is about to go out of
/// date, and where any of it went.
///
/// The expiring tab is what earns the feature in a food or pharmacy
/// business, and two of its decisions are safety decisions.
///
/// ALREADY-EXPIRED STOCK IS ON THE LIST. Deliberately, with a negative
/// number of days, because it is still on the shelf and still on the
/// balance sheet at cost. A list that showed only stock about to expire
/// would drop the batch somebody most needs to pull -- and it would
/// look complete.
///
/// AND THE COUNT READS FORWARDS. `-days` is what makes "expired 12 days
/// ago" rather than "expired -12 days ago", which is the same negation
/// the secretarial desk needs for a late filing and is just as easy to
/// leave out.
///
/// The colour is the third: red only once it is actually a problem,
/// because colouring everything that carries a date teaches people to
/// ignore the colour. The screen says so in its own comment.
void main() {
  Map<String, dynamic> lot({
    String lotId = 'l1',
    String itemCode = 'MILK-1L',
    String itemName = 'Fresh Milk 1L',
    String lotRef = 'B-2609',
    num quantity = 48,
    int? daysToExpiry,
    String? warehouse = 'Main Warehouse',
    num? valueAtAverage,
  }) => {
    'lot_id': lotId,
    'item_code': itemCode,
    'item_name': itemName,
    'lot_ref': lotRef,
    'quantity': quantity,
    'days_to_expiry': daysToExpiry,
    'warehouse': warehouse,
    'value_at_average': valueAtAverage,
  };

  late _FakeRepo repo;

  Widget wrap({
    List<Map<String, dynamic>> balances = const [],
    List<Map<String, dynamic>> expiring = const [],
  }) => ProviderScope(
    overrides: [
      repoProvider.overrideWithValue(repo = _FakeRepo(balances, expiring)),
    ],
    child: MaterialApp(
      theme: AppTheme.light(),
      home: const LotsScreen(),
    ),
  );

  Future<void> show(
    WidgetTester tester, {
    List<Map<String, dynamic>> balances = const [],
    List<Map<String, dynamic>> expiring = const [],
  }) async {
    await tester.pumpWidget(wrap(balances: balances, expiring: expiring));
    await tester.pumpAndSettle();
  }

  Future<void> openExpiring(WidgetTester tester) async {
    await tester.tap(find.text('Expiring'));
    await tester.pumpAndSettle();
  }

  group('stock that has already gone out of date', () {
    testWidgets('is on the list, counting forwards', (tester) async {
      await show(tester, expiring: [
        lot(daysToExpiry: -12, valueAtAverage: 180),
      ]);
      await openExpiring(tester);

      // "expired 12 days ago", not "-12". The batch is still on the
      // shelf; the sentence has to read like something somebody acts on.
      expect(find.textContaining('expired 12 days ago'), findsOneWidget);
      expect(find.textContaining('-12'), findsNothing);
    });

    testWidgets('alongside stock that has not', (tester) async {
      // Both in one list, which is the point: a list of only
      // about-to-expire stock drops the batch most needing pulling and
      // still looks complete.
      await show(tester, expiring: [
        lot(lotId: 'a', lotRef: 'B-2601', daysToExpiry: -3),
        lot(lotId: 'b', lotRef: 'B-2609', daysToExpiry: 21),
      ]);
      await openExpiring(tester);

      expect(find.textContaining('expired 3 days ago'), findsOneWidget);
      expect(find.textContaining('expires in 21 days'), findsOneWidget);
    });

    testWidgets('and expiring today is not yet expired', (tester) async {
      // The boundary. Zero is `expires in 0 days` -- it can still be
      // sold today, and calling it expired pulls saleable stock.
      await show(tester, expiring: [lot(daysToExpiry: 0)]);
      await openExpiring(tester);

      expect(find.textContaining('expires in 0 days'), findsOneWidget);
      expect(find.textContaining('expired'), findsNothing);
    });
  });

  group('the colour, which only means something if it is rare', () {
    testWidgets('expired is danger and inside thirty days is warning',
        (tester) async {
      await show(tester, expiring: [
        lot(lotId: 'a', lotRef: 'B-1', daysToExpiry: -3),
        lot(lotId: 'b', lotRef: 'B-2', daysToExpiry: 10),
      ]);
      await openExpiring(tester);

      final icons = tester
          .widgetList<Icon>(find.byIcon(Icons.warning_amber_outlined))
          .toList();
      expect(icons.length, 2);
      // Two different colours, because "expired" and "expiring" are two
      // different jobs: one is pulled from the shelf, the other is sold
      // first.
      expect(icons[0].color, isNot(icons[1].color));
    });

    testWidgets('and stock with a month in hand carries no warning at all',
        (tester) async {
      // The control, and the screen's own reason: colouring everything
      // that has a date teaches people to ignore the colour.
      await show(tester, expiring: [lot(daysToExpiry: 45)]);
      await openExpiring(tester);

      expect(find.byIcon(Icons.warning_amber_outlined), findsNothing);
      expect(find.byIcon(Icons.inventory_2_outlined), findsOneWidget);
    });
  });

  group('what each tab is for', () {
    testWidgets('on hand can be traced, and carries no cost', (tester) async {
      // Trace is the question a recall asks, and answering it is the
      // only thing that justifies making somebody type a batch number
      // on every receipt.
      await show(tester, balances: [
        lot(quantity: 48, valueAtAverage: 180),
      ]);

      expect(find.text('MILK-1L · B-2609'), findsOneWidget);
      expect(find.text('48'), findsOneWidget);
      expect(find.text('Trace'), findsOneWidget);
      // `value_at_average` is present on the row and must NOT be shown
      // here: this tab answers "what have we got", not "what is it
      // worth".
      expect(find.textContaining('at cost'), findsNothing);
    });

    testWidgets('expiring carries the cost and cannot be traced',
        (tester) async {
      // The cost is here because expired stock is still on the balance
      // sheet, and that figure is the write-off somebody is deciding
      // about.
      await show(tester, expiring: [
        lot(daysToExpiry: -12, valueAtAverage: 180.50),
      ]);
      await openExpiring(tester);

      expect(find.textContaining('at cost RM 180.50'), findsOneWidget);
      expect(find.text('Trace'), findsNothing);
    });

    testWidgets('a lot says which warehouse it is in', (tester) async {
      // Which shelf the batch is on. For a recall that is the whole
      // question, and nothing else on this screen answers it -- without
      // this assertion the field could be dropped entirely and every
      // other test here would still pass.
      await show(tester, balances: [
        lot(itemName: 'Fresh Milk 1L', warehouse: 'Cold Room 2'),
      ]);

      expect(find.textContaining('Fresh Milk 1L  ·  Cold Room 2'),
          findsOneWidget);
    });

    testWidgets('a lot with no warehouse leaves the field out',
        (tester) async {
      await show(tester, balances: [lot(warehouse: null)]);

      expect(find.textContaining('Fresh Milk 1L'), findsOneWidget);
      // The whole subtitle, with the warehouse simply absent.
      //
      // NOT a `textContaining('·  ·')` check for a doubled separator:
      // nothing can produce one here. The `if (r['warehouse'] != null)`
      // guard sits above a `.where((e) => e != null)` that already
      // drops a null, so removing the guard changes nothing and that
      // assertion could never fail. An exact match at least fails if
      // the line grows or loses a field.
      expect(find.text('Fresh Milk 1L'), findsOneWidget);
    });
  });

  group('the window somebody is asking about', () {
    testWidgets('is ninety days until they say otherwise', (tester) async {
      await show(tester);
      await openExpiring(tester);

      final segmented =
          tester.widget<SegmentedButton<int>>(find.byType(SegmentedButton<int>));
      expect(segmented.selected, {90});
      // And the empty message says which window it is talking about, so
      // "nothing expires" cannot be read as "nothing ever expires".
      expect(find.textContaining('Nothing expires in the next 90 days'),
          findsOneWidget);
      expect(repo.lastWithinDays, 90,
          reason: 'the default window is what was actually asked for');
    });

    testWidgets('and changing it re-asks and re-words', (tester) async {
      await show(tester);
      await openExpiring(tester);

      await tester.tap(find.text('30 days'));
      await tester.pumpAndSettle();

      expect(
        tester
            .widget<SegmentedButton<int>>(find.byType(SegmentedButton<int>))
            .selected,
        {30},
      );
      expect(find.textContaining('Nothing expires in the next 30 days'),
          findsOneWidget);

      // And the DATABASE was asked again. Both assertions above pass on
      // a screen that only repaints -- the chip moves, the sentence
      // rewords, and the list underneath is still the answer to the old
      // question. That mutant survived until this line existed.
      expect(repo.lastWithinDays, 30);
    });
  });

  group('nothing tracked yet', () {
    testWidgets('says how a batch comes to exist', (tester) async {
      await show(tester);

      expect(
        find.textContaining('Turn on batch or serial tracking for an item'),
        findsOneWidget,
      );
    });
  });
}

/// Only what the screen asks for.
class _FakeRepo implements Repo {
  _FakeRepo(this.balances, this.expiring);

  final List<Map<String, dynamic>> balances;
  final List<Map<String, dynamic>> expiring;

  /// What `withinDays` the screen last asked for, so the segmented
  /// control can be shown to reach the query rather than only to
  /// repaint itself.
  int? lastWithinDays;

  @override
  Future<List<Map<String, dynamic>>> lotBalances({String? itemId}) async =>
      balances;

  @override
  Future<List<Map<String, dynamic>>> expiringStock({
    int withinDays = 90,
  }) async {
    lastWithinDays = withinDays;
    return expiring;
  }

  @override
  Future<List<Map<String, dynamic>>> traceLot(String lotId) async => const [];

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
        'the lots screen called Repo.${invocation.memberName}, which this '
        'fake does not answer',
      );
}
