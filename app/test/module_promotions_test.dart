import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/data/models.dart';
import 'package:iakauntan/src/features/admin/promotions_admin.dart';
import 'package:iakauntan/src/features/settings/module_offer.dart';

/// A price that is not the price list's.
///
/// 0548 lets a platform operator offer a trial period, give a module
/// away, or price one differently for a while. The arithmetic is the
/// database's and is asserted in `supabase/tests/module_promotions.sql`.
/// What is asserted here is the sentence a customer reads before
/// agreeing to it — because a trial that does not say what happens on
/// day thirty-one is a complaint with a delay on it, and a discount
/// nobody can see the old price beside is just a number.
void main() {
  ModuleSurface module({
    String name = 'Multi-Company',
    double price = 39,
    double? promoPrice,
    String? promotion,
    String? kind,
    int? days,
    DateTime? until,
  }) => ModuleSurface(
    code: 'multi_company',
    name: name,
    isCore: false,
    monthlyPrice: price,
    entitled: false,
    hidden: false,
    visible: false,
    promoPrice: promoPrice,
    promotion: promotion,
    promoKind: kind,
    promoDays: days,
    promoUntil: until,
  );

  group('what a module costs this company', () {
    test('with no promotion it is the price list', () {
      expect(module().price, 39);
      expect(module().isFreeNow, isFalse);
    });

    test('with one it is the promotional price', () {
      final m = module(promoPrice: 29.25, promotion: 'Quarter off',
          kind: 'percent_off');
      expect(m.price, 29.25);
      // And the list price is still there to show it against.
      expect(m.monthlyPrice, 39);
    });

    test('a module given away costs nothing', () {
      final m = module(promoPrice: 0, promotion: 'On the house', kind: 'free');
      expect(m.isFreeNow, isTrue);
    });
  });

  group('the chip', () {
    test('a trial is sold as the days, not as the price', () {
      expect(
        moduleChipLabel(module(
            promoPrice: 0, promotion: 'Thirty days on us',
            kind: 'trial', days: 30)),
        'Multi-Company · free for 30 days',
      );
    });

    test('a giveaway says free rather than RM 0.00', () {
      expect(
        moduleChipLabel(module(
            promoPrice: 0, promotion: 'On the house', kind: 'free')),
        'Multi-Company · free',
      );
    });

    test('a discount carries the price being charged, not the list', () {
      expect(
        moduleChipLabel(module(
            promoPrice: 29.25, promotion: 'Quarter off', kind: 'percent_off')),
        'Multi-Company · RM 29.25/mo',
      );
    });
  });

  group('the note under the list', () {
    test('there is none when nothing is on offer', () {
      expect(modulePromoNote(module()), isNull);
    });

    test('a trial says what happens after it', () {
      final note = modulePromoNote(module(
          promoPrice: 0, promotion: 'Thirty days on us',
          kind: 'trial', days: 30))!;
      expect(note, contains('Thirty days on us'));
      expect(note, contains('first 30 days are free'));
      // The half that stops the complaint on day thirty-one.
      expect(note, contains('RM 39.00 a month'));
    });

    test('a discount names the price it replaced', () {
      final note = modulePromoNote(module(
          promoPrice: 29.25, promotion: 'Quarter off',
          kind: 'percent_off'))!;
      expect(note, contains('RM 29.25 a month'));
      expect(note, contains('instead of RM 39.00'));
    });

    test('and a promotion with an end says when it ends', () {
      final note = modulePromoNote(module(
          promoPrice: 0, promotion: 'On the house', kind: 'free',
          until: DateTime(2026, 3, 31)))!;
      expect(note, contains('31'));
      expect(note, contains('nothing to pay'));
    });
  });

  group('the confirmation', () {
    test('a trial names both numbers', () {
      final prompt = addModulePrompt(module(
          promoPrice: 0, promotion: 'Thirty days on us',
          kind: 'trial', days: 30));
      expect(prompt, contains('first 30 days are free'));
      expect(prompt, contains('RM 39.00 a month'));
      expect(prompt, contains('after that'));
    });

    test('a giveaway does not invent a charge', () {
      final prompt = addModulePrompt(module(
          promoPrice: 0, promotion: 'On the house', kind: 'free'));
      expect(prompt, contains('costs nothing'));
      expect(prompt, isNot(contains('RM 39.00 a month is added')));
    });

    test('a discount says the promotional price and the list price', () {
      final prompt = addModulePrompt(module(
          promoPrice: 29.25, promotion: 'Quarter off', kind: 'percent_off'));
      expect(prompt, contains('RM 29.25 a month'));
      expect(prompt, contains('instead of RM 39.00'));
    });

    test('and with no promotion it is 0488\'s sentence, unchanged', () {
      final prompt = addModulePrompt(module());
      expect(prompt, contains('RM 39.00 a month'));
      expect(prompt, contains('from today'));
      expect(prompt, isNot(contains('instead of')));
    });
  });

  group('taking it off again', () {
    test('names what they are actually paying, not the price list', () {
      // Telling somebody on a free trial that "RM 39.00 a month stops
      // being charged" tells them they are saving money they were never
      // spending.
      final prompt = removeModulePrompt(module(
          promoPrice: 0, promotion: 'Thirty days on us',
          kind: 'trial', days: 30));
      expect(prompt, isNot(contains('RM')));
      expect(prompt, contains('The screens go'));
    });

    test('and the ordinary price when there is no promotion', () {
      expect(removeModulePrompt(module()), contains('RM 39.00 a month'));
    });
  });

  group('what the month cost', () {
    test('a line carries the list amount and the promotion beside it', () {
      final line = ModuleCharge.fromMap({
        'module_code': 'multi_company',
        'name': 'Multi-Company',
        'days': 31,
        'days_in_month': 31,
        'amount': 29.25,
        'list_amount': 39.0,
        'promotion': 'Quarter off',
      });
      expect(line.amount, 29.25);
      expect(line.listAmount, 39.0);
      expect(line.promotion, 'Quarter off');
    });

    test('and the month says what the promotions saved', () {
      final month = SubscriptionMonth.fromMap({
        'month': '2026-01-01',
        'lines': const [],
        'subtotal': 29.25,
        'saved': 9.75,
      });
      expect(month.subtotal, 29.25);
      expect(month.saved, 9.75);
    });

    test('a month from a server that predates 0548 still reads', () {
      // `saved` is absent from an older payload. Zero, not a crash.
      final month = SubscriptionMonth.fromMap({
        'month': '2026-01-01',
        'lines': const [],
        'subtotal': 39.0,
      });
      expect(month.saved, 0);
    });
  });

  group('the console line', () {
    Map<String, dynamic> row(Map<String, dynamic> over) => {
      'name': 'Launch offer',
      'kind': 'trial',
      'trial_days': 30,
      'starts_on': '2026-01-01',
      'ends_on': null,
      ...over,
    };

    test('a trial says how many days', () {
      expect(promotionOffer(row({})), 'Free for the first 30 days');
    });

    test('a percentage says the percentage', () {
      expect(
        promotionOffer(row({'kind': 'percent_off', 'percent_off': 25})),
        '25% off',
      );
    });

    test('a fixed price says the price', () {
      expect(
        promotionOffer(row({'kind': 'fixed_price', 'fixed_price': 10})),
        'RM 10.00 a month',
      );
    });

    test('with no module and no company it says so, rather than nothing', () {
      // The two nulls are the two widest promotions this product can
      // write. A line that left them blank would read as a promotion
      // that applies to nothing.
      final line = promotionSummary(row({}));
      expect(line, contains('Every add-on'));
      expect(line, contains('Every company'));
    });

    test('and names the module and the company when it has them', () {
      final line = promotionSummary(row({
        'module_name': 'Multi-Company',
        'org_name': 'Sinar Teknologi Sdn Bhd',
      }));
      expect(line, contains('Multi-Company'));
      expect(line, contains('Sinar Teknologi Sdn Bhd'));
      expect(line, isNot(contains('Every')));
    });

    test('an open-ended promotion says from, a closed one says to', () {
      expect(promotionSummary(row({})), contains('from'));
      expect(
        promotionSummary(row({'ends_on': '2026-03-31'})),
        contains(' to '),
      );
    });
  });
}
