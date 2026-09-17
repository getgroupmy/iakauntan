import 'package:flutter_test/flutter_test.dart';
import 'package:iakauntan/src/features/pos/recipe_requirement_dialog.dart';

Map<String, dynamic> need(
  String name, {
  num quantity = 1,
  Object? onHand = 10,
  bool optional = false,
  String uom = 'GRM',
}) => <String, dynamic>{
  'component_item_id': 'c-$name',
  'component_name': name,
  'quantity': quantity,
  'uom_code': uom,
  'is_optional': optional,
  'on_hand': onHand,
};

void main() {
  group('how much of an ingredient one dish takes', () {
    test('the quantity and its unit', () {
      expect(requirementLine(need('Rice', quantity: 180)), '180 GRM');
    });

    test('trailing zeros the column carries are trimmed', () {
      // 0.1800 is what the database holds; 0.18 is what a cook wrote.
      expect(requirementLine(need('Salt', quantity: 0.18)), '0.18 GRM');
    });

    test('an optional ingredient says so', () {
      expect(
        requirementLine(need('Coriander', quantity: 2, optional: true)),
        '2 GRM · optional',
      );
    });
  });

  group('how many dishes one ingredient allows', () {
    test('what is on hand divided by what one takes', () {
      expect(portionsFrom(need('Rice', quantity: 180, onHand: 900)), 5);
    });

    test('an ingredient the shop does not count limits nothing', () {
      // Naming it would name the wrong shelf as the constraint.
      expect(portionsFrom(need('Water', onHand: null)), isNull);
    });

    test('an ingredient the recipe needs none of limits nothing', () {
      expect(portionsFrom(need('Garnish', quantity: 0, onHand: 5)), isNull);
    });

    test('none on hand allows none', () {
      expect(portionsFrom(need('Rice', quantity: 180, onHand: 0)), 0);
    });
  });

  group('which ingredient runs out first', () {
    test('the one that allows fewest', () {
      final worst = limitingIngredient([
        need('Rice', quantity: 180, onHand: 1800),
        need('Chicken', quantity: 200, onHand: 800),
        need('Oil', quantity: 10, onHand: 5000),
      ])!;
      expect(worst['component_name'], 'Chicken');
    });

    test('an optional one is never the reason', () {
      // The dish goes out without it, so it does not stop the kitchen
      // making another.
      final worst = limitingIngredient([
        need('Rice', quantity: 180, onHand: 1800),
        need('Coriander', quantity: 5, onHand: 1, optional: true),
      ])!;
      expect(worst['component_name'], 'Rice');
    });

    test('an uncounted one is never the reason either', () {
      final worst = limitingIngredient([
        need('Rice', quantity: 180, onHand: 1800),
        need('Water', quantity: 500, onHand: null),
      ])!;
      expect(worst['component_name'], 'Rice');
    });

    test('nothing counted means no reason to give', () {
      expect(
        limitingIngredient([need('Water', onHand: null)]),
        isNull,
      );
      expect(limitingIngredient(const []), isNull);
    });

    test('a recipe of nothing but optionals has no limit', () {
      expect(
        limitingIngredient([need('Coriander', onHand: 0, optional: true)]),
        isNull,
      );
    });
  });

  group('what the store allows over the whole recipe', () {
    test('is what the tightest ingredient allows', () {
      final n = portionsPossible([
        need('Rice', quantity: 180, onHand: 1800),
        need('Chicken', quantity: 200, onHand: 800),
      ]);
      expect(n, 4);
    });

    test('is nothing to say when nothing counted limits it', () {
      // The same answer the countdown gives: saying "unlimited" would
      // be a promise nobody made.
      expect(portionsPossible([need('Water', onHand: null)]), isNull);
    });

    test('is zero when the tightest has run out', () {
      expect(
        portionsPossible([
          need('Rice', quantity: 180, onHand: 1800),
          need('Chicken', quantity: 200, onHand: 0),
        ]),
        0,
      );
    });
  });
}
