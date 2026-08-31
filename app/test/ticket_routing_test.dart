import 'package:flutter_test/flutter_test.dart';
import 'package:iakauntan/src/data/models.dart';
import 'package:iakauntan/src/features/ticketing/ticket_routing_sheet.dart';

TeamMember member(
  String? userId, {
  String status = 'active',
  String? name,
  String? email,
}) => TeamMember(
  memberId: 'm-${userId ?? 'none'}-$status',
  userId: userId,
  fullName: name,
  email: email,
  role: 'staff',
  status: status,
);

void main() {
  group('who a ticket can be given to', () {
    test('is exactly who assign_ticket would accept', () {
      final team = [
        member('u1', name: 'Aisyah'),
        member(null, status: 'invited', email: 'not.yet@example.com'),
        member('u2', status: 'removed', name: 'Gone'),
        member('u3', name: 'Bala'),
      ];

      final ids = assignableMembers(team).map((m) => m.userId).toList();

      // Active and accepted only: an invitation nobody has taken up has
      // no user_id to name, and a removed member is refused by the
      // function with 23503 rather than assigned.
      expect(ids, ['u1', 'u3']);
    });

    test('an active member who has not accepted is not offered', () {
      // The row exists and is active, but until somebody signs in there
      // is no auth user behind it.
      expect(assignableMembers([member(null)]), isEmpty);
    });

    test('keeps the order the team came in', () {
      final team = [member('u9', name: 'Zul'), member('u1', name: 'Ah Meng')];
      expect(assignableMembers(team).map((m) => m.userId), ['u9', 'u1']);
    });

    // `0355`: a ticket on a team whose membership has been filled in may
    // only be handed to somebody on that team. The list offered has to
    // be the set the server will take, and the empty case is the one
    // that matters — get it wrong and every ticket in every company
    // that has not filled a team in becomes unassignable.
    test('and narrows to the team when the team has a list', () {
      final team = [member('u1'), member('u2'), member('u3')];
      final ids = assignableMembers(
        team,
        roster: [
          {'user_id': 'u1'},
          {'user_id': 'u3'},
        ],
      ).map((m) => m.userId);

      expect(ids, ['u1', 'u3']);
    });

    test('a team with nobody on it offers everybody, not nobody', () {
      // The database reads an empty membership list as "anybody may
      // take these", so this does too. Collapsing empty into "narrow to
      // nothing" would empty the dropdown on every team nobody has
      // filled in.
      final team = [member('u1'), member('u2')];
      expect(
        assignableMembers(team, roster: const []).map((m) => m.userId),
        ['u1', 'u2'],
      );
    });

    test('and a roster that has not arrived yet is not an empty one', () {
      // Null is "we do not know", and offering nobody while a read is in
      // flight is a dropdown that empties and refills under somebody.
      final team = [member('u1'), member('u2')];
      expect(
        assignableMembers(team, roster: null).map((m) => m.userId),
        ['u1', 'u2'],
      );
    });

    test('somebody on the team but no longer in the company is still out',
        () {
      // Both refusals apply, and the org one is the older and blunter:
      // `assign_ticket` raises 23503 for a suspended member whatever
      // team they are on.
      final team = [member('u1'), member('u2', status: 'suspended')];
      expect(
        assignableMembers(team, roster: [
          {'user_id': 'u1'},
          {'user_id': 'u2'},
        ]).map((m) => m.userId),
        ['u1'],
      );
    });
  });

  group('who holds it now', () {
    final team = [
      member('u1', name: 'Aisyah'),
      member('u2', email: 'bala@example.com'),
    ];

    test('nobody is said, not left blank', () {
      expect(assigneeLabel(team, null), 'Nobody yet');
    });

    test('is the person by name', () {
      expect(assigneeLabel(team, 'u1'), 'Aisyah');
    });

    test('falls back to the email of somebody with no name recorded', () {
      expect(assigneeLabel(team, 'u2'), 'bala@example.com');
    });

    test('an assignee who has left still reads as somebody', () {
      // The id survives the person leaving the organization. A ticket
      // that reads as unassigned when it is held by a leaver is a
      // ticket nobody picks up.
      expect(
        assigneeLabel(team, 'u-gone'),
        'Somebody no longer on the team',
      );
    });

    test('with no team loaded yet, an assigned ticket is not called empty', () {
      expect(assigneeLabel(const [], 'u1'), 'Somebody no longer on the team');
      expect(assigneeLabel(const [], null), 'Nobody yet');
    });
  });

  group('handing it over', () {
    test('opens a ticket that is still new', () {
      // Both assign_ticket and escalate_ticket carry the same clause.
      expect(statusAfterHandover('new'), 'open');
    });

    test('leaves every other status where it was', () {
      for (final s in ['open', 'pending', 'on_hold', 'resolved', 'closed']) {
        expect(statusAfterHandover(s), s, reason: s);
      }
    });
  });

  group('which way an escalation goes', () {
    test('there are two kinds and they are the enum', () {
      expect(kEscalationKinds, ['functional', 'hierarchic']);
    });

    test('a functional escalation is about a team', () {
      expect(escalationNeedsTeam('functional'), isTrue);
      expect(escalationNeedsUser('functional'), isFalse);
    });

    test('a hierarchic escalation is about a person', () {
      expect(escalationNeedsUser('hierarchic'), isTrue);
      expect(escalationNeedsTeam('hierarchic'), isFalse);
    });

    test('each says which way it goes', () {
      expect(escalationLabel('functional'), contains('team'));
      expect(escalationLabel('hierarchic'), contains('senior'));
    });
  });

  group('whether escalating means anything', () {
    test('not once the ticket is finished with', () {
      expect(escalationMakesSense('cancelled'), isFalse);
      expect(escalationMakesSense('closed'), isFalse);
    });

    test('yes while it is still live', () {
      for (final s in ['new', 'open', 'pending', 'on_hold', 'resolved']) {
        expect(escalationMakesSense(s), isTrue, reason: s);
      }
    });
  });

  group('the escalation itself', () {
    test('a functional escalation with no team is not one', () {
      // escalate_ticket raises 22023 on this. The button is off first.
      expect(escalationOf(kind: 'functional'), isNull);
      expect(
        escalationOf(kind: 'functional', userId: 'u1'),
        isNull,
        reason: 'naming a person does not make it a functional escalation',
      );
    });

    test('a hierarchic escalation with nobody named is not one', () {
      expect(escalationOf(kind: 'hierarchic'), isNull);
      expect(escalationOf(kind: 'hierarchic', teamId: 't1'), isNull);
    });

    test('functional carries the team and drops the person', () {
      final e = escalationOf(
        kind: 'functional',
        teamId: 't1',
        userId: 'u1',
      )!;
      expect(e.kind, 'functional');
      expect(e.toTeam, 't1');
      // Otherwise the escalation quietly reassigns the ticket to
      // whoever happened to be selected in the other dropdown.
      expect(e.toUser, isNull);
    });

    test('hierarchic carries the person and drops the team', () {
      final e = escalationOf(
        kind: 'hierarchic',
        teamId: 't1',
        userId: 'u1',
      )!;
      expect(e.kind, 'hierarchic');
      expect(e.toUser, 'u1');
      expect(e.toTeam, isNull);
    });

    test('a reason is trimmed', () {
      final e = escalationOf(
        kind: 'functional',
        teamId: 't1',
        reason: '  Customer has escalated to their director  ',
      )!;
      expect(e.reason, 'Customer has escalated to their director');
    });

    test('no reason and a blank reason are the same thing', () {
      expect(escalationOf(kind: 'functional', teamId: 't1')!.reason, isNull);
      expect(
        escalationOf(kind: 'functional', teamId: 't1', reason: '   ')!.reason,
        isNull,
      );
    });
  });
}
