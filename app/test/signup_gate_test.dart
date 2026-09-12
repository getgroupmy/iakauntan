import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/features/auth/signup_gate.dart';

/// What the registration form does when the platform has stopped
/// taking registrations.
///
/// None of this enforces anything. `0018` seeded `signup_enabled` and
/// nothing read it for five hundred migrations; `0563` makes the
/// trigger on `auth.users` refuse, and that is the enforcement. These
/// are the manners: not walking somebody up to a door that will not
/// open, and telling them why rather than removing the button.
void main() {
  group('whether the way on is offered', () {
    test('it is, while registration is open', () {
      expect(
        offersRegistration(signupsOpen: true, alreadyThere: false),
        isTrue,
      );
    });

    test('and is not, once it is closed', () {
      expect(
        offersRegistration(signupsOpen: false, alreadyThere: false),
        isFalse,
      );
    });

    test('but somebody already on the form keeps their way back', () {
      // That half of the toggle says "Already have an account? Sign
      // in". Hiding it strands somebody on a page with no exit — and
      // the person it strands is the one who came to register, who is
      // exactly who this is being polite to.
      expect(
        offersRegistration(signupsOpen: false, alreadyThere: true),
        isTrue,
      );
    });
  });

  group('whether the button works', () {
    test('only while it is open', () {
      expect(canRegister(signupsOpen: true), isTrue);
      expect(canRegister(signupsOpen: false), isFalse);
    });
  });

  group('what somebody is told', () {
    test('the operator\'s own words, where they wrote any', () {
      expect(closedNotice('We open again on the first of April.'),
          'We open again on the first of April.');
      expect(closedNotice('  Back in April.  '), 'Back in April.');
    });

    test('and a sentence rather than nothing, where they did not', () {
      // A blank notice is a page that lost its button. "We are closed"
      // with no reason reads as a fault, and somebody who believes the
      // site is broken comes back tomorrow and tries again.
      for (final said in [null, '', '   ']) {
        expect(closedNotice(said), isNotEmpty);
        expect(closedNotice(said).toLowerCase(), contains('not taking'));
      }
    });

    test('and it says the one way in that still works', () {
      // Closing public registration was never about somebody a company
      // invited, and the person reading this is the one who most needs
      // to know that.
      expect(closedNotice(null).toLowerCase(), contains('invit'));
    });
  });
}
