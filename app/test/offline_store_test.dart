import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:iakauntan/src/features/pos/offline_store.dart';

/// Selling with no signal, from the device's side.
///
/// Two things are asserted here and nowhere else. The first is the
/// payload shape: `app.land_offline_sale` reads specific keys, and a
/// device that sent `item` instead of `item_id` would queue a day of
/// takings that every flush rejects. The second is the change — the one
/// figure a till with no signal is forced to work out for itself, and
/// the one place in this application where a rule is deliberately
/// implemented twice.
void main() {
  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
  });

  group('the coins to collect', () {
    // The same worked examples `supabase/tests/pos.sql` asserts against
    // `app.pos_cash_due`. Written to agree with it: when the batch
    // lands, `complete_pos_sale` computes this again and that answer is
    // the one that posts, so the two disagreeing is a defect the
    // customer sees as a wrong handful of coins.
    test('rounds to the nearest five sen', () {
      expect(cashDue(10.03), 10.05);
      expect(cashDue(10.02), 10.00);
      expect(cashDue(10.07), 10.05);
      expect(cashDue(10.08), 10.10);
      // Already on a five sen boundary, so untouched.
      expect(cashDue(10.05), 10.05);
      expect(cashDue(12.00), 12.00);
    });

    test('rounds what is left after the card, not the basket', () {
      // 0208's rule: a basket split between card and cash rounds only
      // the remainder the cash is settling.
      expect(cashDue(20.03, nonCash: 10.00), 10.05);
      // Covered entirely by card: nothing to round and nothing to
      // collect.
      expect(cashDue(20.03, nonCash: 20.03), 0);
      expect(cashDue(20.03, nonCash: 25.00), 0);
    });

    test('leaves it alone for a shop that turned rounding off', () {
      expect(cashDue(10.03, round: false), 10.03);
    });

    test('says what rounding did, signed', () {
      // Positive: the customer paid more than the basket.
      expect(roundingAdjustment(10.03), closeTo(0.02, 0.0001));
      // Negative: less.
      expect(roundingAdjustment(10.02), closeTo(-0.02, 0.0001));
      // A basket that needed no rounding carries no adjustment at all,
      // which is the assertion that stops a card-only sale posting a
      // stray sen.
      expect(roundingAdjustment(12.00), 0);
      expect(roundingAdjustment(20.03, nonCash: 20.03), 0);
    });
  });

  group('the client id', () {
    test('is a version 4 uuid Postgres will accept', () {
      final id = newClientUuid();
      expect(
        RegExp(
          r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-'
          r'[0-9a-f]{12}$',
        ).hasMatch(id),
        isTrue,
        reason: 'app.land_offline_sale casts it to uuid: $id',
      );
    });

    test('is different every time', () {
      // Why the generator takes `Random.secure()` and not the default
      // `Random()`: two phones seeded from the same clock tick would
      // otherwise produce the same id, and the unique index on
      // (org_id, client_uuid) would make one shop's sale silently
      // swallow another's.
      final ids = {for (var i = 0; i < 200; i++) newClientUuid()};
      expect(ids.length, 200);

      // And a seeded generator still produces a well-formed one, which
      // is what makes the shape assertion above reproducible.
      expect(newClientUuid(Random(1)).length, 36);
    });
  });

  group('the payload', () {
    OfflineSale sale({String id = 'c-1'}) => OfflineSale(
      clientUuid: id,
      registerId: 'reg-1',
      outletId: 'out-1',
      soldAt: DateTime.utc(2026, 8, 19, 4, 30),
      lines: [
        const OfflineLine(
          itemId: 'item-1',
          description: 'Roti canai',
          quantity: 2,
          unitPrice: 2.00,
          modifiers: ['mod-1'],
        ),
      ],
      tenders: [const OfflineTender(typeId: 'tender-cash', amount: 5.00)],
    );

    test('is exactly the shape land_offline_sale reads', () {
      final p = sale().toPayload();

      expect(p['client_uuid'], 'c-1');
      expect(p['sold_at'], '2026-08-19T04:30:00.000Z');

      final line = (p['lines'] as List).single as Map<String, dynamic>;
      expect(line['item_id'], 'item-1');
      expect(line['quantity'], 2);
      expect(line['unit_price'], 2.00);
      expect(
        (line['modifiers'] as List).single,
        {'modifier_id': 'mod-1'},
      );
      // The description is ours, for the screen. The item decides what
      // it is called when the sale lands, so sending it would be
      // sending a label as if it were a fact.
      expect(line.containsKey('description'), isFalse);

      final tender = (p['tenders'] as List).single as Map<String, dynamic>;
      expect(tender['type'], 'tender-cash');
      expect(tender['amount'], 5.00);
    });

    test('survives being written and read back', () {
      final back = OfflineSale.fromJson(sale().toJson());
      expect(back.clientUuid, 'c-1');
      expect(back.registerId, 'reg-1');
      expect(back.lines.single.description, 'Roti canai');
      expect(back.lines.single.modifiers, ['mod-1']);
      expect(back.tenders.single.amount, 5.00);
      expect(back.total, 4.00);
    });
  });

  group('the queue', () {
    test('keeps sales in the order they were taken', () async {
      final store = await PosOfflineStore.open();
      await store.enqueue(_stub('a'));
      await store.enqueue(_stub('b'));

      final queue = store.queue();
      expect([for (final s in queue) s.clientUuid], ['a', 'b']);
    });

    test('will not queue the same sale twice', () async {
      final store = await PosOfflineStore.open();
      await store.enqueue(_stub('a'));
      await store.enqueue(_stub('a'));

      // A save retried after a crash must not double the day's takings
      // before they have even been sent.
      expect(store.queue().length, 1);
    });

    test('forgets what the server accounted for, and only that', () async {
      final store = await PosOfflineStore.open();
      await store.enqueue(_stub('a'));
      await store.enqueue(_stub('b'));
      await store.enqueue(_stub('c'));

      // `landed`, `already` and `rejected` all come off: a rejected
      // payload kept locally would retry for ever, and the server has
      // already written it to pos_offline_rejects for somebody to look
      // at.
      await store.forget({'a', 'c'});
      expect([for (final s in store.queue()) s.clientUuid], ['b']);
    });

    test('is read back out of storage, not held in the object', () async {
      final store = await PosOfflineStore.open();
      await store.enqueue(_stub('a'));

      // A second store reading the same storage. The queue is not
      // cached in the object at all — every read goes to disk, which is
      // what makes a relaunch after a crash find the day's takings.
      final reopened = await PosOfflineStore.open();
      expect(reopened.queue().single.clientUuid, 'a');
    });

    test('a corrupt queue empties rather than stopping the till', () async {
      SharedPreferences.setMockInitialValues({
        PosOfflineStore.queueKey: 'not json',
      });
      final store = await PosOfflineStore.open();
      // Refusing to sell because of an unreadable queue would turn a
      // lost record into a lost day.
      expect(store.queue(), isEmpty);
    });
  });

  group('the cached menu', () {
    test('is kept per outlet', () async {
      final store = await PosOfflineStore.open();
      await store.cacheMenu('out-1', [
        {'item_id': 'i-1', 'name': 'Teh tarik', 'unit_price': '3.00'},
      ]);

      expect(store.cachedMenu('out-1').single['name'], 'Teh tarik');
      // A device moved to another shop must not sell the first shop's
      // menu.
      expect(store.cachedMenu('out-2'), isEmpty);
    });
  });
  group('what the cashier typed into the tender box', () {
    // Three answers, not two. Both tills used to write
    // `double.tryParse(text) ?? total`, which made the second
    // indistinguishable from the first.

    test('an empty box is exact money', () {
      // The right default at a counter: most sales are paid exactly and
      // nobody should have to retype the total.
      expect(tenderTyped('', exact: 43.50), 43.50);
      expect(tenderTyped('   ', exact: 43.50), 43.50);
    });

    test('a figure is the figure', () {
      expect(tenderTyped('100', exact: 43.50), 100);
      expect(tenderTyped('50.25', exact: 43.50), 50.25);
      expect(tenderTyped('43.50', exact: 43.50), 43.50);
    });

    test('and it is read the way money is written at a till', () {
      expect(tenderTyped('RM 100', exact: 43.50), 100);
      expect(tenderTyped('1,000', exact: 43.50), 1000);
      expect(tenderTyped(' 100 ', exact: 43.50), 100);
    });

    test('a box that cannot be read is not exact money', () {
      // The defect. A hundred ringgit handed over for a basket of
      // 43.50, with the letter O typed for a nought: `?? total` made
      // the cash in equal the cash due, `0209` worked the change out as
      // `round(v_cashin - v_cashdue, 2)`, and the customer walked away
      // 56.50 short.
      expect(tenderTyped('1OO', exact: 43.50), isNull);
      expect(tenderTyped('one hundred', exact: 43.50), isNull);
      expect(tenderTyped('50,5', exact: 43.50), isNull);
    });

    test('and the old reading really did call it exact money', () {
      // The control, so these read as a defect rather than as numbers.
      expect(double.tryParse('1OO') ?? 43.50, 43.50);
      expect(double.tryParse('one hundred') ?? 43.50, 43.50);
    });

    test('a nought is a figure, not an empty box', () {
      // Somebody taking nothing in cash on a split tender. It must not
      // fall through to the exact amount.
      expect(tenderTyped('0', exact: 43.50), 0);
    });
  });

}

OfflineSale _stub(String id) => OfflineSale(
  clientUuid: id,
  registerId: 'reg-1',
  outletId: 'out-1',
  soldAt: DateTime.utc(2026, 8, 19),
  lines: const [
    OfflineLine(
      itemId: 'item-1',
      description: 'Teh tarik',
      quantity: 1,
      unitPrice: 3.00,
    ),
  ],
  tenders: const [OfflineTender(typeId: 'tender-cash', amount: 3.00)],
);
