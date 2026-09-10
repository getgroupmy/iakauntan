import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/features/onboarding/onboarding_copy.dart';

/// The questions setup asks before the form, and what the form says
/// once they are answered.
///
/// One of these decisions reaches LHDN. A person invoicing under their
/// own name is identified by a MyKad number, and a form that asks them
/// for an SSM registration number gets an empty box — which is a
/// rejected e-Invoice, found out about weeks later by somebody who
/// thought they had invoiced.
void main() {
  group('what this is for', () {
    test('is not the same question as what kind of company', () {
      // The distinction the whole flow rests on: a sole proprietor is a
      // business with a registration number, and a freelancer is not.
      expect(UseKind.values.length, 2);
      expect(personalEntityType, 'individual');
    });

    test('and both answers say what they mean', () {
      expect(personalBlurb.toLowerCase(), contains('your own name'));
      expect(personalBlurb, contains('MyKad'));
      expect(businessBlurb.toLowerCase(), contains('ssm'));
    });
  });

  group('the name box', () {
    test('asks a company for its registered name', () {
      expect(nameLabel(UseKind.business, malaysian: true), 'Company name *');
      expect(nameLabel(UseKind.business, malaysian: false), 'Company name *');
    });

    test('and a person for the name on the document that identifies them', () {
      // LHDN matches the name against the identification it was filed
      // under, so a shortened name is a rejected submission.
      expect(nameLabel(UseKind.personal, malaysian: true), contains('MyKad'));
      expect(
        nameLabel(UseKind.personal, malaysian: false),
        contains('passport'),
      );
    });
  });

  group('the identification box', () {
    test('is the SSM number for a business, anywhere', () {
      expect(
        identificationLabel(UseKind.business, malaysian: true),
        'SSM registration no.',
      );
    });

    test('is the MyKad number for a person in Malaysia', () {
      expect(
        identificationLabel(UseKind.personal, malaysian: true),
        'MyKad number',
      );
      // The assertion that would fail if the label were left as one
      // string: an SSM box in front of somebody who has never had one
      // is a box left empty.
      expect(
        identificationLabel(UseKind.personal, malaysian: true),
        isNot(contains('SSM')),
      );
    });

    test('and the passport number for a person without one', () {
      expect(
        identificationLabel(UseKind.personal, malaysian: false),
        'Passport number',
      );
      expect(
        identificationHint(UseKind.personal, malaysian: false),
        isNot(contains('2023')),
      );
    });

    test('says where the number goes, either way', () {
      for (final use in UseKind.values) {
        expect(identificationHelp(use).toLowerCase(), contains('lhdn'));
      }
      // And says what it stands in for, where it stands in for
      // something.
      expect(
        identificationHelp(UseKind.personal),
        contains('business registration'),
      );
    });
  });

  group('what the setup promises', () {
    test('names the Malaysian instruments at home', () {
      final promise = setupPromise(malaysian: true, use: UseKind.business);
      expect(promise, contains('Malaysian'));
      expect(promise, contains('SST'));
    });

    test('and promises neither of them anywhere else', () {
      // A company in Singapore told it is getting SST tax codes has
      // been promised something it did not want.
      final promise = setupPromise(malaysian: false, use: UseKind.business);
      expect(promise, isNot(contains('Malaysian')));
      expect(promise, isNot(contains('SST')));
      expect(promise, contains('chart of accounts'));
    });

    test('and does not offer a person a sales pipeline', () {
      final promise = setupPromise(malaysian: true, use: UseKind.personal);
      expect(promise, isNot(contains('pipeline')));
      expect(promise, contains('your own name'));
    });

    test('the heading follows too', () {
      expect(setupTitle(UseKind.business), 'Set up your company');
      expect(setupTitle(UseKind.personal), isNot(contains('company')));
    });
  });

  group('what a business type says it adds', () {
    test('names them rather than counting them', () {
      // "Adds 3 modules" tells nobody whether the answer is right for
      // them, and being able to tell is the point of asking.
      expect(modulesAdded(['Point of Sale']), 'Adds Point of Sale');
      expect(
        modulesAdded(['Point of Sale', 'Loyalty & Points']),
        'Adds Point of Sale and Loyalty & Points',
      );
      expect(
        modulesAdded(['A', 'B', 'C']),
        'Adds A, B and C',
      );
    });

    test('and says so when it adds nothing', () {
      // "Something else" carries nothing on purpose: it is the answer
      // that means ask me instead.
      expect(modulesAdded(const []).toLowerCase(), contains('you choose'));
      expect(otherBusinessType, 'other');
    });
  });

  group('what it costs, before anything is agreed to', () {
    test('a price is a price', () {
      expect(monthlyPrice(79), 'RM 79 a month');
    });

    test('and nothing is free rather than RM 0.00', () {
      // A column of RM 0.00 beside RM 79.00 reads as an oversight.
      expect(monthlyPrice(0), 'Free');
      expect(monthlyPrice(null), 'Free');
    });

    test('the total says what will actually be charged', () {
      expect(monthlyTotal(108), contains('RM 108'));
      expect(monthlyTotal(0).toLowerCase(), contains('nothing extra'));
      expect(monthlyTotal(0), isNot(contains('RM')));
    });

    test('and the list is not required', () {
      expect(modulesBlurb.toLowerCase(), contains('none of these are'));
    });
  });

  group('forty trades in a readable order', () {
    final rows = [
      {'code': 'restaurant', 'sector': 'Food and drink'},
      {'code': 'food_stall', 'sector': 'Food and drink'},
      {'code': 'retail_shop', 'sector': 'Retail'},
      {'code': 'other', 'sector': 'Other'},
    ];

    test('grouped by sector', () {
      final groups = bySector(rows);
      expect(groups.keys.toList(), ['Food and drink', 'Retail', 'Other']);
      expect(groups['Food and drink']!.length, 2);
    });

    test('keeping the order the query gave, which is deliberate', () {
      // `sort_order` puts the commonest sector first and "Something
      // else" last. Sorting the sectors by name here would undo that.
      final groups = bySector(rows);
      expect(groups.keys.last, 'Other');
      expect(
        groups['Food and drink']!.map((r) => r['code']).toList(),
        ['restaurant', 'food_stall'],
      );
    });

    test('and nothing is lost on the way', () {
      final groups = bySector(rows);
      expect(
        groups.values.expand((v) => v).length,
        rows.length,
      );
      expect(bySector(const []), isEmpty);
    });
  });
}
