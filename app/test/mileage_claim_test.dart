import 'package:flutter_test/flutter_test.dart';
import 'package:iakauntan/src/features/hr/mileage_claim.dart';

/// Claiming by the kilometre rather than by the ringgit.
void main() {
  Map<String, dynamic> type({
    bool mileage = true,
    num? rate = 0.60,
    String? unit = 'kilometre',
  }) => {
    'id': 't',
    'name': 'Mileage',
    'is_mileage': mileage,
    'rate_per_unit': rate,
    'unit_label': unit,
  };

  group('which types are measured', () {
    test('the one that says so', () {
      expect(isMileage(type()), isTrue);
    });

    test('and nothing else, including nothing at all', () {
      // Null is the first frame, before the types arrive.
      expect(isMileage(type(mileage: false)), isFalse);
      expect(isMileage(null), isFalse);
      expect(isMileage({'id': 't'}), isFalse);
    });
  });

  group('what the box is called', () {
    test('the unit the shop named', () {
      // "Quantity" does not tell somebody they are being asked for
      // kilometres, and a form that has to be explained is one people
      // get wrong.
      expect(claimQuantityLabel(type()), 'How many kilometres *');
    });

    test('and something sensible when it named none', () {
      expect(claimQuantityLabel(type(unit: null)), 'How many *');
      expect(claimQuantityLabel(type(unit: '  ')), 'How many *');
    });
  });

  group('what it comes to', () {
    test('the distance at the rate', () {
      expect(mileageAmount(claimType: type(), quantity: '120'), 72.00);
    });

    test('rounded to the sen, the way the database rounds it', () {
      // 0.60 x 33.333 is 19.9998, and a claim form showing RM19.9998 is
      // a claim form nobody trusts.
      expect(mileageAmount(claimType: type(), quantity: '33.333'), 20.00);
    });

    test('and nothing at all before there is a distance', () {
      for (final q in const ['', '  ', '0', '-5', 'far']) {
        expect(mileageAmount(claimType: type(), quantity: q), isNull,
            reason: q);
      }
    });

    test('nor for a type that is not measured', () {
      expect(
        mileageAmount(claimType: type(mileage: false), quantity: '120'),
        isNull,
      );
    });

    test('nor when nobody has set a rate', () {
      expect(mileageAmount(claimType: type(rate: 0), quantity: '120'), isNull);
      expect(mileageAmount(claimType: type(rate: null), quantity: '120'),
          isNull);
    });
  });

  group('whether it can be filed', () {
    test('an ordinary type is never blocked by this', () {
      // The guard belongs to one kind of claim. Applied to all of them
      // it would stop every ordinary claim in the company.
      expect(
        mileageBlockedBecause(claimType: type(mileage: false), quantity: ''),
        isNull,
      );
    });

    test('a measured one needs a distance', () {
      expect(
        mileageBlockedBecause(claimType: type(), quantity: ''),
        'Say how many.',
      );
    });

    test('and a rate somebody has actually set', () {
      // The database refuses this too; saying so here saves the round
      // trip and names the thing to go and fix.
      final why = mileageBlockedBecause(claimType: type(rate: 0), quantity: '120');
      expect(why, isNotNull);
      expect(why, contains('rate'));
    });

    test('with both, it goes', () {
      expect(mileageBlockedBecause(claimType: type(), quantity: '120'), isNull);
    });
  });
}
