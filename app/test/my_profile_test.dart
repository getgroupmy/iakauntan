import 'package:flutter_test/flutter_test.dart';
import 'package:iakauntan/src/features/profile/my_profile.dart';

/// The pure core of the profile screen.
///
/// The load-bearing ones are [profileChanged] and [profileChanges].
/// Between them they decide whether Save is pressable and what a press
/// sends, and `0649` reads a null as "leave this column alone" and an
/// empty string as "clear it" -- so a helper that returned the wrong
/// one of those would either refuse to let somebody remove a telephone
/// number or would blank a field they never touched.
void main() {
  const blank = (fullName: '', salutation: '', phone: '');

  group('opening the form', () {
    test('a row becomes a draft', () {
      expect(
        profileDraftFrom(const {
          'full_name': 'Ahmad Ismail',
          'salutation': 'Mr',
          'phone': '+60123456789',
        }),
        (fullName: 'Ahmad Ismail', salutation: 'Mr', phone: '+60123456789'),
      );
    });

    test('nulls become empty strings, not the word null', () {
      // A text box has no null. Treating the two differently is how a
      // form decides it has been edited before anybody touches it.
      expect(
        profileDraftFrom(const {
          'full_name': 'Ahmad',
          'salutation': null,
          'phone': null,
        }),
        (fullName: 'Ahmad', salutation: '', phone: ''),
      );
    });

    test('a missing row is a blank draft, not a crash', () {
      expect(profileDraftFrom(null), blank);
      expect(profileDraftFrom(const {}), blank);
    });

    test('surrounding space is taken off', () {
      // Otherwise a row stored with a trailing space reports itself as
      // edited the moment the form opens, and Save is live before
      // anybody has typed.
      final draft = profileDraftFrom(const {'full_name': '  Ahmad  '});
      expect(draft.fullName, 'Ahmad');
      expect(profileChanged(draft, draft), isFalse);
    });
  });

  group('whether there is anything to save', () {
    test('an untouched draft has not changed', () {
      final draft = profileDraftFrom(const {'full_name': 'Ahmad'});
      expect(profileChanged(draft, draft), isFalse);
    });

    test('a changed name has', () {
      expect(
        profileChanged(
          (fullName: 'Ahmad', salutation: '', phone: ''),
          (fullName: 'Ahmad Ismail', salutation: '', phone: ''),
        ),
        isTrue,
      );
    });

    test('a changed salutation has, on its own', () {
      // The field nobody thinks of as a change. Saving the form without
      // it would drop a title somebody had just chosen.
      expect(
        profileChanged(
          (fullName: 'Ahmad', salutation: '', phone: ''),
          (fullName: 'Ahmad', salutation: 'Datuk', phone: ''),
        ),
        isTrue,
      );
    });

    test('an EMPTIED phone has', () {
      // The one a naive "is anything filled in" check gets wrong.
      // Clearing a field is an edit.
      expect(
        profileChanged(
          (fullName: 'Ahmad', salutation: '', phone: '+60123456789'),
          (fullName: 'Ahmad', salutation: '', phone: ''),
        ),
        isTrue,
      );
    });
  });

  group('what a save sends', () {
    test('only the fields that moved', () {
      expect(
        profileChanges(
          (fullName: 'Ahmad', salutation: 'Mr', phone: '+60111'),
          (fullName: 'Ahmad Ismail', salutation: 'Mr', phone: '+60111'),
        ),
        {'fullName': 'Ahmad Ismail'},
      );
    });

    test('nothing when nothing moved', () {
      final draft = (fullName: 'Ahmad', salutation: 'Mr', phone: '+60111');
      expect(profileChanges(draft, draft), isEmpty);
    });

    test('an emptied field is sent as an empty string, not omitted', () {
      // THE ONE THAT MATTERS. `0649` coalesces a null to the existing
      // value, so omitting an emptied field means the telephone number
      // stays on file and the screen shows it gone until the next
      // reload. Somebody who removed their mobile number would find it
      // back.
      expect(
        profileChanges(
          (fullName: 'Ahmad', salutation: 'Mr', phone: '+60111'),
          (fullName: 'Ahmad', salutation: 'Mr', phone: ''),
        ),
        {'phone': ''},
      );
    });

    test('a field whose only change is space is not sent', () {
      expect(
        profileChanges(
          (fullName: 'Ahmad', salutation: '', phone: ''),
          (fullName: '  Ahmad  ', salutation: '', phone: ''),
        ),
        isEmpty,
      );
    });

    test('everything at once', () {
      expect(
        profileChanges(blank, (
          fullName: 'Ahmad Ismail',
          salutation: 'Datuk',
          phone: '+60123456789',
        )),
        {
          'fullName': 'Ahmad Ismail',
          'salutation': 'Datuk',
          'phone': '+60123456789',
        },
      );
    });
  });

  group('one field at a time', () {
    test('an unchanged field is null, which means leave it alone', () {
      expect(profileFieldToSend('Ahmad', 'Ahmad'), isNull);
    });

    test('a changed field is the new value, trimmed', () {
      expect(profileFieldToSend('Ahmad', '  Ahmad Ismail '), 'Ahmad Ismail');
    });

    test('an emptied field is the empty string, which means clear it', () {
      expect(profileFieldToSend('+60111', ''), '');
      expect(profileFieldToSend('+60111', '   '), '');
    });
  });

  group('the name', () {
    test('a real one is accepted', () {
      expect(profileNameProblem('Ahmad Ismail'), isNull);
      expect(profileNameProblem('Wu'), isNull);
    });

    test('an empty one is refused', () {
      // The name on every letter and on anything this person approves.
      // Blank shows as blank in the member list, the approval inbox and
      // the audit trail, and none of those has anywhere else to look.
      expect(profileNameProblem(''), isNotNull);
      expect(profileNameProblem('   '), isNotNull);
    });

    test('a single character is refused', () {
      // A keystroke, not a name, and the commonest way this column gets
      // one is somebody clearing the box and pressing Save.
      expect(profileNameProblem('A'), isNotNull);
    });

    test('an absurdly long one is refused', () {
      expect(profileNameProblem('x' * 121), isNotNull);
      expect(profileNameProblem('x' * 120), isNull);
    });
  });

  group('what to call somebody', () {
    test('the name when there is one', () {
      expect(
        profileDisplayName(const {'full_name': 'Ahmad', 'email': 'a@b.c'}),
        'Ahmad',
      );
    });

    test('the email when there is not', () {
      expect(
        profileDisplayName(const {'full_name': '', 'email': 'a@b.c'}),
        'a@b.c',
      );
    });

    test('a word when there is neither', () {
      // Not hypothetical: `close_my_account` (0158) sets the name to
      // "Deleted user" and the email to NULL, so a row with neither is
      // a state this schema deliberately produces.
      expect(profileDisplayName(const {}), 'Your account');
      expect(profileDisplayName(null), 'Your account');
    });

    test('the title goes in front for a heading', () {
      expect(
        profileFormalName(const {'full_name': 'Ahmad', 'salutation': 'Mr'}),
        'Mr Ahmad',
      );
    });

    test('and no stray space when there is no title', () {
      expect(profileFormalName(const {'full_name': 'Ahmad'}), 'Ahmad');
    });
  });

  group('when the database refuses', () {
    test('each of the three refusals 0649 can raise gets its own words', () {
      expect(
        profileSaveProblem(Exception('Not signed in')),
        contains('signed out'),
      );
      expect(
        profileSaveProblem(Exception('This login has been closed.')),
        contains('has been closed'),
      );
      expect(
        profileSaveProblem(Exception('No profile on file for this login.')),
        contains('ours to fix'),
      );
    });

    test('and the three are different sentences', () {
      final said = {
        profileSaveProblem(Exception('Not signed in')),
        profileSaveProblem(Exception('This login has been closed.')),
        profileSaveProblem(Exception('No profile on file for this login.')),
      };
      expect(said.length, 3);
    });

    test('anything else is passed through rather than swallowed', () {
      // A sentence written for a developer beats a sentence written
      // for nobody.
      expect(
        profileSaveProblem(Exception('connection closed')),
        contains('connection closed'),
      );
    });
  });
}
