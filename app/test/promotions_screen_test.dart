import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/features/pos/promotions_screen.dart';

/// A price the shop decided in advance.
///
/// What a promotion does to the money is asserted in
/// `supabase/tests/pos.sql`. What is asserted here is the sentence a
/// shopkeeper checks their own rule against — the one place a screen
/// can send somebody away believing they published something other than
/// what they published, and the takings are how they would find out.
void main() {
  Map<String, dynamic> promo({
    required String kind,
    num percent = 0,
    num amount = 0,
    int buy = 0,
    int get = 0,
    String? startsAt,
    String? endsAt,
    List<int>? weekdays,
    String? startsOn,
    String? endsOn,
  }) => {
    'kind': kind,
    'percent': '$percent',
    'amount': '$amount',
    'buy_quantity': buy,
    'get_quantity': get,
    'starts_at': startsAt,
    'ends_at': endsAt,
    'weekdays': weekdays,
    'starts_on': startsOn,
    'ends_on': endsOn,
  };

  group('what the rule says', () {
    test('a rate reads as a rate', () {
      expect(promotionRule(promo(kind: 'percent_off', percent: 10)), '10% off');
    });

    test('and an amount as money', () {
      expect(
        promotionRule(promo(kind: 'amount_off', amount: 5)),
        'RM 5.00 off',
      );
    });

    test('three for two is said as buy two get one free', () {
      // "Three for two" is what a shop says out loud and is only true
      // at a hundred per cent. What is shown is what was actually
      // saved, because that is what the till will charge.
      expect(
        promotionRule(
          promo(kind: 'buy_x_get_y', percent: 100, buy: 2, get: 1),
        ),
        'Buy 2, get 1 free',
      );
    });

    test('and half price on the third is not called free', () {
      expect(
        promotionRule(promo(kind: 'buy_x_get_y', percent: 50, buy: 2, get: 1)),
        'Buy 2, get 1 at 50% off',
      );
    });
  });

  group('when it runs', () {
    test('nothing set means always, and says nothing', () {
      expect(promotionWindow(promo(kind: 'percent_off', percent: 10)), isNull);
    });

    test('an hours window drops the seconds Postgres sends', () {
      expect(
        promotionWindow(
          promo(
            kind: 'percent_off',
            percent: 10,
            startsAt: '11:00:00',
            endsAt: '15:30:00',
          ),
        ),
        '11:00–15:30',
      );
    });

    test('weekdays are named, Monday first', () {
      expect(
        promotionWindow(
          promo(kind: 'percent_off', percent: 10, weekdays: [1, 2, 3]),
        ),
        'Mon Tue Wed',
      );
    });

    test('every day is not worth saying', () {
      // Seven of seven is the same as none, and a row that spells out
      // "Mon Tue Wed Thu Fri Sat Sun" buries the part that matters.
      expect(
        promotionWindow(
          promo(
            kind: 'percent_off',
            percent: 10,
            weekdays: [1, 2, 3, 4, 5, 6, 7],
          ),
        ),
        isNull,
      );
    });

    test('a window and hours read as one line', () {
      expect(
        promotionWindow(
          promo(
            kind: 'percent_off',
            percent: 10,
            startsOn: '2026-08-01',
            endsOn: '2026-08-31',
            weekdays: [6, 7],
            startsAt: '18:00:00',
            endsAt: '21:00:00',
          ),
        ),
        '01/08/2026 – 31/08/2026 · Sat Sun · 18:00–21:00',
      );
    });
  });
}
