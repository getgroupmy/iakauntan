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
      expect(
        personalBlurb(SetupAudience.own).toLowerCase(),
        contains('your own name'),
      );
      expect(personalBlurb(SetupAudience.own), contains('MyKad'));
      expect(businessBlurb.toLowerCase(), contains('ssm'));
    });

    test('and are about the right person', () {
      // The same screen serves an accounting practice opening books for
      // a client. "Myself" and "your MyKad" are the wrong words in
      // front of a bookkeeper typing in somebody else's number.
      expect(personalTitle(SetupAudience.own), 'Myself');
      expect(personalTitle(SetupAudience.other), 'An individual');
      expect(
        personalBlurb(SetupAudience.other).toLowerCase(),
        contains('their own name'),
      );
      expect(useQuestion(SetupAudience.other).toLowerCase(),
          contains('these books'));
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

    test('and says whose name it wants', () {
      expect(
        nameLabel(UseKind.personal, malaysian: true),
        contains('your MyKad'),
      );
      expect(
        nameLabel(
          UseKind.personal,
          malaysian: true,
          audience: SetupAudience.other,
        ),
        contains('their MyKad'),
      );
      // A company's name is its own whoever is typing.
      expect(
        nameLabel(
          UseKind.business,
          malaysian: true,
          audience: SetupAudience.other,
        ),
        'Company name *',
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

    test('and so does the button that ends it', () {
      // Reported: a person who had answered "Myself" all the way
      // through was asked at the last moment to Create company, which
      // is the form saying they are in the wrong place.
      expect(createButtonLabel(UseKind.business), 'Create company');
      expect(createButtonLabel(UseKind.personal), 'Open my books');
      expect(
        createButtonLabel(UseKind.personal).toLowerCase(),
        isNot(contains('company')),
      );
      // And a practice opening books for a client is not opening its
      // own.
      expect(
        createButtonLabel(UseKind.personal, audience: SetupAudience.other),
        'Open these books',
      );
    });

    test('a practice is told whose books it is opening', () {
      expect(
        setupTitle(UseKind.personal, audience: SetupAudience.other),
        'Set up these books',
      );
      expect(
        setupTitle(UseKind.business, audience: SetupAudience.other),
        'Add a company',
      );
      expect(
        setupPromise(
          malaysian: true,
          use: UseKind.personal,
          audience: SetupAudience.other,
        ),
        contains('their own name'),
      );
      expect(
        identificationHelp(UseKind.personal, audience: SetupAudience.other),
        contains('their invoices'),
      );
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

  group('going back does not start again', () {
    test('a person goes straight to the modules', () {
      // There is no business type to choose, because they are not one.
      expect(stepAfterUse(UseKind.personal), SetupStep.modules);
      expect(
        stepAfterUse(UseKind.personal, businessType: 'restaurant'),
        SetupStep.modules,
      );
    });

    test('a business with nothing chosen yet goes to the type list', () {
      expect(stepAfterUse(UseKind.business), SetupStep.businessType);
    });

    test('and one that has already chosen goes on to the form', () {
      // The assertion this whole group exists for: somebody who went
      // back to look at the first question, and answered it the same
      // way, must not be asked the second one again.
      expect(
        stepAfterUse(UseKind.business, businessType: 'law_firm'),
        SetupStep.form,
      );
    });

    test('"Something else" goes to the list, everything else to the form', () {
      expect(stepAfterBusinessType(otherBusinessType), SetupStep.modules);
      expect(stepAfterBusinessType('restaurant'), SetupStep.form);
    });

    test('becoming a person drops the business type', () {
      // Leaving a stale one would file somebody invoicing under their
      // own name as a restaurant.
      expect(clearsBusinessType(UseKind.personal), isTrue);
      expect(clearsBusinessType(UseKind.business), isFalse);
    });

    test('and the ticks are replaced only by a different trade', () {
      // A law firm that unticked timesheets, went back to check the
      // list and tapped "Law firm" again would otherwise find
      // timesheets ticked once more.
      expect(
        replacesTicks(current: 'law_firm', chosen: 'law_firm'),
        isFalse,
      );
      expect(
        replacesTicks(current: 'law_firm', chosen: 'restaurant'),
        isTrue,
      );
      expect(replacesTicks(current: null, chosen: 'restaurant'), isTrue);
    });
  });

  group('the lines that say what was answered', () {
    test('name the answer rather than the code', () {
      expect(useAnswer(UseKind.business), businessTitle);
      expect(useAnswer(UseKind.personal), personalTitle(SetupAudience.own));
      // And the summary line agrees with the card that was tapped.
      expect(
        useAnswer(UseKind.personal, SetupAudience.other),
        personalTitle(SetupAudience.other),
      );
    });

    test('and say what having chosen nothing means', () {
      expect(modulesSummary(0).toLowerCase(), contains('always on'));
      expect(modulesSummary(0), isNot(contains('0')));
      expect(modulesSummary(3), '3 chosen');
    });

    test('each has a label somebody can match to the step it opens', () {
      expect(useFieldLabel, useFieldLabel.trim());
      expect(businessTypeFieldLabel.toLowerCase(), contains('business'));
      expect(modulesFieldLabel, isNotEmpty);
    });
  });
}
