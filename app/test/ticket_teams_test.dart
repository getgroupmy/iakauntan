import 'package:flutter_test/flutter_test.dart';
import 'package:iakauntan/src/features/ticketing/teams.dart';

/// Support teams, and who is on one.
///
/// `0192` built the membership table and nothing ever wrote a row, so
/// routing existed and decided nothing. `0355` makes the list decide —
/// and, when it is empty, decline to. The empty case is asserted hardest
/// on both sides of the wire, because getting it wrong there makes every
/// ticket in every company that never filled one in unassignable.
void main() {
  group('a code from a name', () {
    test('is typeable and stable', () {
      expect(teamCode('Billing'), 'billing');
      expect(teamCode('Billing & Credit Control'), 'billing_credit_control');
      expect(teamCode('  Front  Desk  '), 'front_desk');
    });

    test('and a name with nothing usable in it still yields one', () {
      // `(org_id, code)` is unique and not null. A name in a script this
      // slug cannot carry must still produce something insertable.
      expect(teamCode('***'), 'team');
      expect(teamCode(''), 'team');
      expect(teamCode('客服'), 'team');
    });
  });

  group('what stops a team being saved', () {
    test('a name, first of all', () {
      expect(teamBlockedBecause(name: '', takenCodes: const []),
          contains('needs a name'));
      expect(teamBlockedBecause(name: '   ', takenCodes: const []),
          contains('needs a name'));
    });

    test('and a name that is already a team', () {
      expect(
        teamBlockedBecause(name: 'Billing', takenCodes: const ['billing']),
        contains('already a team'),
      );
      // Two names that slug the same way are the same clash, and the
      // database would refuse them with a constraint name.
      expect(
        teamBlockedBecause(name: 'billing', takenCodes: const ['billing']),
        isNotNull,
      );
    });

    test('but renaming a team to its own name is not a clash', () {
      expect(
        teamBlockedBecause(
          name: 'Billing',
          takenCodes: const ['billing'],
          editingCode: 'billing',
        ),
        isNull,
      );
    });

    test('a fresh name goes through', () {
      expect(
        teamBlockedBecause(name: 'Dispatch', takenCodes: const ['billing']),
        isNull,
      );
    });
  });

  group('the line under a team', () {
    test('says who leads it', () {
      final roster = [
        {'user_id': 'a', 'full_name': 'Aida', 'is_lead': true},
        {'user_id': 'b', 'full_name': 'Ben', 'is_lead': false},
      ];
      expect(rosterSummary(roster), '2 people, led by Aida');
    });

    test('and says so when nobody does', () {
      final roster = [
        {'user_id': 'a', 'full_name': 'Aida', 'is_lead': false},
      ];
      expect(rosterSummary(roster), '1 person, no lead');
    });

    test('and an empty team reads as the setting it is', () {
      // Not "no members" — that reads as missing data. A team nobody is
      // on accepts any assignee, which is a live consequence somebody
      // should be able to see from the list.
      final said = rosterSummary(const []);
      expect(said, contains('Anybody can be given these'));
      expect(said, contains('nobody is on it'));
    });
  });

  group('a person in the list', () {
    test('is named when there is a name', () {
      expect(memberName({'full_name': 'Aida', 'email': 'a@x.my'}), 'Aida');
    });

    test('and by address when there is not', () {
      // `profiles.full_name` is null until somebody fills it in, and a
      // blank line is how a team looks empty when it is not.
      expect(memberName({'full_name': null, 'email': 'a@x.my'}), 'a@x.my');
      expect(memberName({'full_name': '  ', 'email': 'a@x.my'}), 'a@x.my');
    });

    test('and still says something when there is neither', () {
      expect(memberName(const {}), isNot(''));
    });
  });

  group('who is left to add', () {
    final orgTeam = [
      {'user_id': 'a', 'status': 'active'},
      {'user_id': 'b', 'status': 'active'},
      {'user_id': 'c', 'status': 'suspended'},
      // Active and still with no auth user behind them: the row exists
      // and is active, and until they sign in there is nobody to name.
      // `status` alone does not catch this one.
      {'user_id': null, 'status': 'active'},
    ];

    test('is the active members who are not on it already', () {
      final left = addableTo(
        orgTeam: orgTeam,
        roster: [
          {'user_id': 'a'},
        ],
      );
      expect(left.map((m) => m['user_id']), ['b']);
    });

    test('never somebody suspended', () {
      final left = addableTo(orgTeam: orgTeam, roster: const []);
      expect(left.map((m) => m['user_id']), ['a', 'b']);
    });

    test('and never an active member who has not signed in yet', () {
      // The row is active — so the status check lets it through — and
      // there is no user id to name. `assign_ticket` would refuse them
      // with 23503, and a dropdown entry that always fails is worse
      // than one that is not offered.
      final left = addableTo(orgTeam: orgTeam, roster: const []);
      expect(left.any((m) => m['user_id'] == null), isFalse);
      expect(left.length, 2);
    });
  });
}
