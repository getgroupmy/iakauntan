import 'package:flutter_test/flutter_test.dart';
import 'package:iakauntan/src/core/theme.dart';
import 'package:iakauntan/src/features/stock/bundles_screen.dart';

void main() {
  group('bundleSummary', () {
    test('says how many parts and what they are worth', () {
      expect(
        bundleSummary({'parts': 3, 'price': 60, 'cost': 29}),
        '3 parts · RM 60.00 for RM 29.00 of stock',
      );
    });

    test('and gets the singular right', () {
      expect(
        bundleSummary({'parts': 1, 'price': 20, 'cost': 12}),
        '1 part · RM 20.00 for RM 12.00 of stock',
      );
    });
  });

  group('marginLabel', () {
    test('names the margin and the percentage', () {
      expect(
        marginLabel({'margin': 31, 'margin_pct': 51.67}),
        'RM 31.00 margin · 51.7%',
      );
    });

    test('says plainly when a bundle is sold under its own parts', () {
      // The mistake this screen exists to catch. A bare "-RM 5.00"
      // is a number somebody has to notice; this is a sentence.
      expect(
        marginLabel({'margin': -5, 'margin_pct': -10}),
        'Sold for RM 5.00 less than the parts cost',
      );
    });

    test('and when it exactly breaks even', () {
      expect(
        marginLabel({'margin': 0, 'margin_pct': 0}),
        'Sold for exactly what the parts cost',
      );
    });

    test('drops the percentage when the price is nothing', () {
      expect(marginLabel({'margin': 29}), 'RM 29.00 margin');
    });
  });

  group('availabilityLabel', () {
    test('says how many and what runs out first', () {
      expect(
        availabilityLabel({'can_make': 100, 'limiting_item': 'Biscuit tin'}),
        '100 can be made · Biscuit tin runs out first',
      );
    });

    test('and names what is missing when none can be made', () {
      expect(
        availabilityLabel({'can_make': 0, 'limiting_item': 'Biscuit tin'}),
        'None can be made — no Biscuit tin',
      );
    });
  });

  group('canSaveBundle', () {
    test('needs an item and at least one part with a quantity', () {
      expect(canSaveBundle(null, [PartDraft(itemId: 'a')]), isFalse);
      expect(canSaveBundle('set', []), isFalse);
      expect(canSaveBundle('set', [PartDraft()]), isFalse);
      expect(
        canSaveBundle('set', [PartDraft(itemId: 'a', quantity: 0)]),
        isFalse,
      );
      expect(canSaveBundle('set', [PartDraft(itemId: 'a')]), isTrue);
    });

    test('refuses the same part twice', () {
      // Two rows for the same item would insert two lines and the
      // second would win silently, so the quantity somebody typed
      // first would vanish.
      expect(
        canSaveBundle('set', [
          PartDraft(itemId: 'a', quantity: 1),
          PartDraft(itemId: 'a', quantity: 2),
        ]),
        isFalse,
      );
    });
  });

  group('what a bundle margin claims', () {
    test('bad news when it is priced under its own parts', () {
      expect(marginTone({'margin': -1}), Tone.bad);
      expect(marginTone({'margin': -0.01}), Tone.bad);
    });

    test('worth looking at when it is priced at exactly what they cost', () {
      // Selling at cost is not a mistake and not a healthy price. The
      // boundary is exact: a sen either side is a different statement
      // about the same shelf.
      expect(marginTone({'margin': 0}), Tone.warn);
      expect(marginTone({'margin': 0.01}), isNull);
    });

    test('and nothing at all when there is a margin', () {
      expect(marginTone({'margin': 12.5}), isNull);
    });

    test('a bundle nobody has costed claims nothing', () {
      // Null is "not worked out yet", not "priced at cost". Amber there
      // would put a warning on every bundle the moment it is created.
      expect(marginTone(null), isNull);
    });
  });

}
