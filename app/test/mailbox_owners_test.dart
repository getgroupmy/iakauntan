import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/data/models.dart';
import 'package:iakauntan/src/features/settings/mailbox_owners.dart';

TeamMember _member({
  String? userId = 'u1',
  String? name = 'Aisyah',
  String? email = 'aisyah@example.com',
  String status = 'active',
}) =>
    TeamMember(
      memberId: 'm-$userId',
      userId: userId,
      email: email,
      fullName: name,
      role: 'accounts_clerk',
      status: status,
    );

/// Whose an address is, on the screen that lists them.
///
/// `0559` built the whole model — shared, personal, and personal with
/// nobody left on it — and nothing in the app reached any of it. The
/// list drew every address as though it were the company's, which is
/// the opposite of true for one with somebody's name on it, and the
/// rule was enforced and invisible.
void main() {
  group('what the line under an address says', () {
    test('a company address says so', () {
      expect(
        mailboxOwnerLabel(const {'is_personal': false}, const {}),
        'Shared with the company',
      );
      // And a row from before 0559 carries no flag at all.
      expect(
        mailboxOwnerLabel(const {}, const {}),
        'Shared with the company',
      );
    });

    test('a personal one names the person', () {
      expect(
        mailboxOwnerLabel(
          const {'is_personal': true, 'owner_id': 'u1'},
          const {'u1': 'Aisyah'},
        ),
        'Aisyah',
      );
    });

    test('and still says it is somebody\'s when it cannot name them', () {
      // Saying "shared" here would be the opposite of true, and the
      // person reading the list is deciding whether to send from it.
      expect(
        mailboxOwnerLabel(
          const {'is_personal': true, 'owner_id': 'u9'},
          const {'u1': 'Aisyah'},
        ),
        'One of your colleagues',
      );
    });

    test('and says why nobody owns an orphaned one', () {
      // `on delete set null`. This is the one case where an
      // administrator can read a personal mailbox, so the list has to
      // say why rather than leaving a blank.
      final line = mailboxOwnerLabel(
        const {'is_personal': true, 'owner_id': null},
        const {},
      );
      expect(line.toLowerCase(), contains('closed'));
      expect(line.toLowerCase(), isNot(contains('shared')));
    });
  });

  group('the button that moves one', () {
    test('says which direction is available', () {
      expect(handOverLabel(const {'is_personal': false}),
          'Give it to somebody');
      expect(handOverLabel(const {'is_personal': true}), 'Move or give back');
    });

    test('and the warning says what giving it back costs', () {
      // Not reversible in the way people assume: every message already
      // in it becomes readable by every member.
      expect(handOverWarning(null).toLowerCase(), contains('everybody'));
      expect(handOverWarning(null).toLowerCase(), contains('cannot be undone'));
    });

    test('and what handing it over costs', () {
      expect(handOverWarning('u1').toLowerCase(), contains('only they'));
      expect(handOverWarning('u1').toLowerCase(), contains('you will not'));
    });
  });

  group('who an address can be given to', () {
    test('somebody who works here and has an account', () {
      expect(mailboxOwnerCandidates([_member()]).length, 1);
    });

    test('and not an invitation nobody has accepted', () {
      // `request_mailbox` and `assign_mailbox` both refuse a member
      // with no account, so offering one is offering a choice the
      // database is about to refuse.
      expect(
        mailboxOwnerCandidates([_member(userId: null)]),
        isEmpty,
      );
      expect(
        mailboxOwnerCandidates([_member(status: 'invited')]),
        isEmpty,
      );
    });
  });

  group('what to call somebody', () {
    test('their name', () {
      expect(memberLabel(_member()), 'Aisyah');
    });

    test('their address, where there is no name yet', () {
      // An invited member who has not filled anything in is still
      // somebody a mailbox might be for.
      expect(memberLabel(_member(name: '')), 'aisyah@example.com');
      expect(memberLabel(_member(name: null)), 'aisyah@example.com');
    });

    test('and something rather than an empty row', () {
      expect(memberLabel(_member(name: null, email: null)), 'A colleague');
    });
  });

  group('the map the list reads names out of', () {
    test('holds everybody with an account', () {
      final map = namesById([
        _member(),
        _member(userId: 'u2', name: 'Mei Ling', email: 'mei@example.com'),
        _member(userId: null),
      ]);
      expect(map, {'u1': 'Aisyah', 'u2': 'Mei Ling'});
    });
  });
}
