import 'package:flutter_test/flutter_test.dart';
import 'package:iakauntan/src/features/settings/tax_exemption.dart';

/// LHDN's list, as 0011 seeds it.
List<Map<String, dynamic>> reasons() => [
  {'code': 'EX01',
    'description': 'Exempted under Sales Tax (Persons Exempted From '
        'Payment Of Tax) Order'},
  {'code': 'EX03', 'description': 'Zero-rated / exported goods and services'},
  {'code': 'EX99', 'description': 'Other exemption (specify)'},
];

void main() {
  group('why an exempt code cannot be saved', () {
    test('without saying what exempts it', () {
      // The column is nullable and the prepare step carries whatever is
      // in it, so nothing downstream refuses this.
      expect(
        exemptionBlockedBecause(isExempt: true, reason: null),
        contains('has to say what exempts it'),
      );
      expect(
        exemptionBlockedBecause(isExempt: true, reason: '   '),
        isNotNull,
      );
    });

    test('and a code that is not exempt is never blocked', () {
      expect(exemptionBlockedBecause(isExempt: false, reason: null), isNull);
    });

    test('an exempt code with a reason is fine', () {
      expect(
        exemptionBlockedBecause(isExempt: true, reason: 'EX01'),
        isNull,
      );
    });
  });

  group('the reason a code carries', () {
    test('is what was chosen while it is exempt', () {
      expect(exemptionOf(isExempt: true, reason: 'EX01'), 'EX01');
      expect(exemptionOf(isExempt: true, reason: ' EX03 '), 'EX03');
    });

    test('and is nothing the moment it stops being exempt', () {
      // A reason left behind on a code that now charges tax would go
      // out on a line that is not exempt at all.
      expect(exemptionOf(isExempt: false, reason: 'EX01'), isNull);
    });

    test('a blank is nothing rather than an empty string', () {
      expect(exemptionOf(isExempt: true, reason: '  '), isNull);
      expect(exemptionOf(isExempt: true, reason: null), isNull);
    });
  });

  test('one reads as its code and the order behind it', () {
    expect(
      exemptionLabel(reasons()[1]),
      'EX03 · Zero-rated / exported goods and services',
    );
  });

  group('what the field shows', () {
    test('the code and the order it is exempt under', () {
      expect(
        exemptionSummary(reasons(), 'EX99'),
        'EX99 · Other exemption (specify)',
      );
    });

    test('however it was stored', () {
      expect(exemptionSummary(reasons(), ' EX99 '), startsWith('EX99 · '));
    });

    test('a code the list no longer carries is still shown', () {
      // An order withdrawn since the code was set is still what the
      // code was set under.
      expect(exemptionSummary(reasons(), 'EX07'), 'EX07');
    });

    test('and nothing chosen says so', () {
      expect(exemptionSummary(reasons(), null), 'Not said');
      expect(exemptionSummary(reasons(), ''), 'Not said');
    });
  });
}
