import 'package:flutter_test/flutter_test.dart';
import 'package:iakauntan/src/features/pos/stalls_screen.dart';

void main() {
  group('stallSummary', () {
    test('is whose it is, what the court keeps, and what is on it', () {
      expect(
        stallSummary({
          'operator': 'Nasi Kandar Pak Din',
          'commission_percent': 15,
          'item_count': 6,
        }),
        'Nasi Kandar Pak Din · 15% commission · 6 dishes',
      );
    });

    test('singular for one dish, because 1 dishes reads wrong', () {
      // The whole string, not a `contains`: "1 dishes" contains
      // "1 dish", so a loose match would pass on the bug.
      expect(
        stallSummary({
          'operator': 'Kak Yah',
          'commission_percent': 10,
          'item_count': 1,
        }),
        'Kak Yah · 10% commission · 1 dish',
      );
    });

    test('and says plainly when a stall has nothing on the menu', () {
      // A stall with no dishes settles at zero, and nobody would know
      // why unless the list says so.
      expect(
        stallSummary({
          'operator': 'Kak Yah',
          'commission_percent': 10,
          'item_count': 0,
        }),
        contains('nothing on the menu yet'),
      );
    });

    test('trimming the zeros a numeric column carries', () {
      expect(
        stallSummary({
          'operator': 'X',
          'commission_percent': 12.5000,
          'item_count': 2,
        }),
        contains('12.5% commission'),
      );
    });
  });

  group('settlementLine', () {
    test('is the three numbers somebody reads before money moves', () {
      expect(
        settlementLine({'gross': 21, 'commission': 3.15, 'net': 17.85}),
        'RM 21.00 sold · RM 3.15 kept · RM 17.85 owed',
      );
    });
  });

  group('canSettle', () {
    final now = DateTime(2026, 8, 22, 14, 0);
    final yesterday = DateTime(2026, 8, 21);

    test('a period that is over, with takings, and nothing paid yet', () {
      expect(
        canSettle([
          {'gross': 21, 'settled': false},
        ], yesterday, now),
        isTrue,
      );
    });

    test('but not one that is still trading', () {
      expect(
        canSettle([
          {'gross': 21, 'settled': false},
        ], DateTime(2026, 8, 22), now),
        isFalse,
      );
    });

    test('nor one where a stall has already been paid', () {
      expect(
        canSettle([
          {'gross': 21, 'settled': false},
          {'gross': 7, 'settled': true},
        ], yesterday, now),
        isFalse,
      );
    });

    test('nor a week in which nobody sold anything', () {
      expect(
        canSettle([
          {'gross': 0, 'settled': false},
        ], yesterday, now),
        isFalse,
      );
    });

    test('nor an empty court', () {
      expect(canSettle(const [], yesterday, now), isFalse);
    });
  });

  group('trimPercent', () {
    test('keeps a whole number whole', () => expect(trimPercent(15), '15'));
    test('and a real fraction', () => expect(trimPercent(12.5), '12.5'));
    test('dropping only the padding', () => expect(trimPercent(0.25), '0.25'));
  });
}
