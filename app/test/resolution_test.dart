import 'package:flutter_test/flutter_test.dart';
import 'package:iakauntan/src/features/secretarial/resolution_sheet.dart';

void main() {
  group('the kinds a resolution can be', () {
    test('are the four the enum has, and no others', () {
      // app.corp_resolution_kind, 0061.
      expect(kResolutionKinds.keys.toList(), [
        'board',
        'members_ordinary',
        'members_special',
        'written',
      ]);
    });

    test('and one nobody recognises reads as itself', () {
      expect(resolutionKindName('board'), 'Directors');
      expect(resolutionKindName('something_else'), 'something_else');
      expect(resolutionKindName(null), '');
    });
  });

  group('what share of the votes cast it needs', () {
    test('three quarters for a special resolution', () {
      // Companies Act 2016, s.292(1).
      expect(majorityNeeded('members_special'), 0.75);
    });

    test('and a simple majority for everything else', () {
      expect(majorityNeeded('board'), 0.5);
      expect(majorityNeeded('members_ordinary'), 0.5);
      expect(majorityNeeded('written'), 0.5);
    });
  });

  group('how many votes were cast', () {
    test('for and against, and nothing else', () {
      expect(votesCast(7, 3), 10);
    });

    test('one side alone is still a count', () {
      expect(votesCast(7, null), 7);
      expect(votesCast(null, 3), 3);
    });

    test('and nothing recorded is not nought', () {
      // A resolution minuted without a count is perfectly ordinary,
      // and calling it nought votes would make it fail.
      expect(votesCast(null, null), isNull);
    });
  });

  group('whether it carried', () {
    test('a simple majority carries an ordinary resolution', () {
      expect(
        resolutionCarried(kind: 'members_ordinary', inFavour: 6, against: 4),
        isTrue,
      );
    });

    test('exactly half carries it', () {
      // "Not less than" a simple majority: five of ten is the line and
      // the line is met.
      expect(
        resolutionCarried(kind: 'members_ordinary', inFavour: 5, against: 5),
        isTrue,
      );
    });

    test('but exactly half does not carry a special one', () {
      expect(
        resolutionCarried(kind: 'members_special', inFavour: 5, against: 5),
        isFalse,
      );
    });

    test('three quarters exactly does carry a special one', () {
      expect(
        resolutionCarried(kind: 'members_special', inFavour: 15, against: 5),
        isTrue,
      );
    });

    test('and one vote short does not', () {
      expect(
        resolutionCarried(kind: 'members_special', inFavour: 14, against: 6),
        isFalse,
      );
    });

    test('nobody counted is not the same as nobody voting for it', () {
      expect(
        resolutionCarried(kind: 'board', inFavour: null, against: null),
        isNull,
      );
      expect(resolutionCarried(kind: 'board', inFavour: 0, against: 0), isNull);
    });
  });

  group('whether the votes fit the people present', () {
    test('they do when they add up to no more', () {
      expect(
        votesFitThePresent(present: 7, inFavour: 4, against: 2, abstained: 1),
        isTrue,
      );
    });

    test('and they do not when there are more votes than people', () {
      // Nothing in the database checks this: present_person_ids is an
      // array and the three counts are plain integers.
      expect(
        votesFitThePresent(present: 7, inFavour: 6, against: 2, abstained: 1),
        isFalse,
      );
    });

    test('abstentions take up a seat even though they are not votes', () {
      expect(
        votesFitThePresent(present: 3, inFavour: 2, against: 1, abstained: 1),
        isFalse,
      );
    });

    test('nobody recorded as present checks nothing', () {
      // A minute that does not list who was there is incomplete, not
      // contradictory.
      expect(votesFitThePresent(present: 0, inFavour: 9), isTrue);
    });
  });

  group('whether it was circulated rather than met over', () {
    test('a written resolution always was', () {
      expect(wasCirculated('written', false), isTrue);
    });

    test('and anything with no meeting was', () {
      expect(wasCirculated('board', false), isTrue);
    });

    test('but a board resolution passed at a meeting was not', () {
      expect(wasCirculated('board', true), isFalse);
    });
  });

  group('why a resolution cannot be saved', () {
    test('without saying what it is', () {
      expect(
        resolutionBlockedBecause(
          title: '  ',
          kind: 'board',
          meetingHeld: true,
        ),
        'A resolution needs to say what it is.',
      );
    });

    test('a written one cannot have been passed at a meeting', () {
      expect(
        resolutionBlockedBecause(
          title: 'Allotment',
          kind: 'written',
          meetingHeld: true,
        ),
        contains('s.297'),
      );
    });

    test('it cannot take effect before it was passed', () {
      expect(
        resolutionBlockedBecause(
          title: 'Allotment',
          kind: 'board',
          meetingHeld: true,
          passedOn: DateTime(2026, 3, 10),
          effectiveOn: DateTime(2026, 3, 9),
        ),
        'It cannot take effect before it was passed.',
      );
    });

    test('but taking effect the same day is ordinary', () {
      expect(
        resolutionBlockedBecause(
          title: 'Allotment',
          kind: 'board',
          meetingHeld: true,
          passedOn: DateTime(2026, 3, 10),
          effectiveOn: DateTime(2026, 3, 10),
        ),
        isNull,
      );
    });

    test('signed without saying when is refused', () {
      expect(
        resolutionBlockedBecause(
          title: 'Allotment',
          kind: 'board',
          meetingHeld: true,
          isSigned: true,
        ),
        'Say when it was signed.',
      );
    });

    test('and more votes than people present', () {
      expect(
        resolutionBlockedBecause(
          title: 'Allotment',
          kind: 'board',
          meetingHeld: true,
          present: 3,
          inFavour: 4,
        ),
        'More votes than people present.',
      );
    });

    test('a complete one is not blocked', () {
      expect(
        resolutionBlockedBecause(
          title: 'Allotment of 1,000 ordinary shares',
          kind: 'board',
          meetingHeld: true,
          passedOn: DateTime(2026, 3, 10),
          present: 3,
          inFavour: 3,
          isSigned: true,
          signedOn: DateTime(2026, 3, 10),
        ),
        isNull,
      );
    });
  });

  group('the values it is written down as', () {
    test('a meeting keeps where it was and who was there', () {
      final v = resolutionValues(
        entityId: 'e1',
        title: ' Allotment ',
        kind: 'board',
        meetingHeld: true,
        venue: 'Level 8, Menara ABC',
        chairmanId: 'p1',
        present: const ['p1', 'p2'],
        passedOn: DateTime(2026, 3, 10),
      );
      expect(v['title'], 'Allotment');
      expect(v['meeting_held'], isTrue);
      expect(v['meeting_venue'], 'Level 8, Menara ABC');
      expect(v['chairman_person_id'], 'p1');
      expect(v['present_person_ids'], ['p1', 'p2']);
      expect(v['passed_on'], '2026-03-10');
    });

    test('a circulated one keeps none of it', () {
      // Carried over from an earlier edit, a venue would say a meeting
      // happened that did not.
      final v = resolutionValues(
        entityId: 'e1',
        title: 'Allotment',
        kind: 'written',
        meetingHeld: false,
        venue: 'Level 8, Menara ABC',
        chairmanId: 'p1',
        present: const ['p1'],
      );
      expect(v['meeting_held'], isFalse);
      expect(v['meeting_venue'], isNull);
      expect(v['chairman_person_id'], isNull);
      expect(v['present_person_ids'], isNull);
    });

    test('an empty box is null rather than an empty string', () {
      final v = resolutionValues(
        entityId: 'e1',
        title: 'Allotment',
        kind: 'board',
        meetingHeld: true,
        reference: '   ',
        body: '',
      );
      expect(v['reference'], isNull);
      expect(v['body'], isNull);
    });

    test('a date signed is dropped when the switch is off', () {
      final v = resolutionValues(
        entityId: 'e1',
        title: 'Allotment',
        kind: 'board',
        meetingHeld: true,
        isSigned: false,
        signedOn: DateTime(2026, 3, 10),
      );
      expect(v['is_signed'], isFalse);
      expect(v['signed_on'], isNull);
    });
  });

  group('what removing one takes with it', () {
    test('anything generated from it stays, and stops naming it', () {
      // corp_documents, corp_filings and corp_share_events all
      // reference it `on delete set null`.
      expect(
        resolutionDeletionWarning(const {'title': 'Allotment'}),
        'Anything generated from it stays, and stops naming the '
        'resolution that authorised it.',
      );
    });

    test('and a signed one says so first', () {
      expect(
        resolutionDeletionWarning(const {
          'title': 'Allotment',
          'is_signed': true,
        }),
        startsWith('This one has been signed.'),
      );
    });
  });

  group('what a row says under its title', () {
    test('the kind, the date and whether it carried', () {
      expect(
        resolutionLine({
          'kind': 'members_special',
          'passed_on': '2026-03-10',
          'in_favour': 15,
          'against': 5,
          'is_signed': true,
        }),
        contains('carried'),
      );
    });

    test('one nobody has passed says so', () {
      expect(
        resolutionLine({'kind': 'board', 'passed_on': null}),
        'Directors · not yet passed',
      );
    });

    test('and one with no count says nothing about carrying', () {
      expect(
        resolutionLine({'kind': 'board', 'passed_on': '2026-03-10'}),
        isNot(contains('carried')),
      );
    });
  });
}
