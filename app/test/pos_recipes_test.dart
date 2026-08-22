import 'package:flutter_test/flutter_test.dart';
import 'package:iakauntan/src/features/pos/recipes_screen.dart';
import 'package:iakauntan/src/features/pos/till_screen.dart';

void main() {
  group('recipeLine', () {
    test('is the quantity and the unit a cook wrote', () {
      expect(
        recipeLine({'quantity': 180, 'uom_code': 'GRM'}),
        '180 GRM',
      );
    });

    test('mentions waste only when there is any', () {
      expect(
        recipeLine({
          'quantity': 200,
          'uom_code': 'GRM',
          'wastage_percent': 10,
        }),
        '200 GRM · 10% waste',
      );
      expect(
        recipeLine({'quantity': 200, 'uom_code': 'GRM', 'wastage_percent': 0}),
        '200 GRM',
      );
    });

    test('and says when a line is a garnish', () {
      expect(
        recipeLine({
          'quantity': 1,
          'uom_code': 'C62',
          'is_optional': true,
        }),
        '1 C62 · optional',
      );
    });

    test('trims the trailing zeros a numeric column carries', () {
      expect(recipeLine({'quantity': 0.1800, 'uom_code': 'KGM'}), '0.18 KGM');
    });
  });

  group('trimNumber', () {
    test('keeps a whole number whole', () => expect(trimNumber(3), '3'));
    test('keeps what matters', () => expect(trimNumber(0.0125), '0.0125'));
    test('drops what does not', () => expect(trimNumber(1.5000), '1.5'));
  });

  group('portionsLabel', () {
    test('a stop is what the till is told, ahead of any count', () {
      expect(
        portionsLabel({'off_reason': 'Beras habis', 'portions': 40}),
        'Beras habis',
      );
    });

    test('says nothing when nothing counted limits it', () {
      expect(portionsLabel({'portions': null}), isNull);
    });

    test('counts down while there is something left', () {
      expect(portionsLabel({'portions': 4}), '4 left');
    });

    test('and names what ran out when there is not', () {
      expect(
        portionsLabel({'portions': 0, 'limiting_item_name': 'Telur'}),
        'Out of telur',
      );
    });

    test('falling back to plain out when it cannot say which', () {
      expect(portionsLabel({'portions': 0}), 'Out');
    });
  });

  group('tileSubtitle', () {
    test('is the price on a dish with no recipe', () {
      expect(tileSubtitle('RM 12.00', null), 'RM 12.00');
    });

    test('and the price and the count on one that has', () {
      expect(tileSubtitle('RM 12.00', 3), 'RM 12.00 · 3 left');
    });

    test('but never a count of nothing, which the greying already says', () {
      expect(tileSubtitle('RM 12.00', 0), 'RM 12.00');
    });
  });
}
