import 'package:flutter_test/flutter_test.dart';
import 'package:iakauntan/src/features/team/invitations.dart';

/// Handing an invitation over, and taking one up.
///
/// The rule that decides is in `0353` and asserted in
/// `supabase/tests/invitations.sql`: the token is matched as a digest,
/// and the caller has to be signed in as the address the invitation
/// names. Nothing here can check either of those, and nothing here
/// tries — what is asserted is only what the two screens say.
void main() {
  group('after inviting somebody', () {
    test('a new invitation comes with something to send', () {
      final said = invitedOutcome(email: 'aida@sinar.my', token: 'a' * 64);

      expect(said, contains('aida@sinar.my'));
      expect(said, contains('Nobody else can use it'));
      expect(said, contains('14 days'));
    });

    test('and a role change does not, because there is nothing to send', () {
      // `invite_member` returns null when the address was already a
      // member. Telling them to "send the code below" when there is no
      // code below is the failure this separates out.
      final said = invitedOutcome(email: 'aida@sinar.my', token: null);

      expect(said, contains('already in this company'));
      expect(said, isNot(contains('code below')));
    });

    test('and the screen knows which of the two it is holding', () {
      expect(hasCodeToGive('a' * 64), isTrue);
      expect(hasCodeToGive(null), isFalse);
      expect(hasCodeToGive(''), isFalse);
    });
  });

  group('a code somebody pastes', () {
    test('survives the whitespace a chat app wrapped it in', () {
      expect(cleanCode('  ${'a' * 64}\n'), 'a' * 64);
    });

    test('and the upper case a mail client capitalised', () {
      expect(cleanCode('A' * 64), 'a' * 64);
    });

    test('an empty box asks for the code rather than refusing it', () {
      // Two different sentences: one is "you have not done anything
      // yet" and the other is "what you did is wrong".
      expect(joinBlockedBecause(''), contains('Paste the code'));
      expect(joinBlockedBecause('   '), contains('Paste the code'));
    });

    test('something the wrong length is refused before the round trip', () {
      expect(joinBlockedBecause('a' * 63), isNotNull);
      expect(joinBlockedBecause('a' * 65), isNotNull);
      expect(joinBlockedBecause('abc'), isNotNull);
    });

    test('and something that is not hex, however long', () {
      // The token is two v4 UUIDs with the dashes taken out, so it is
      // hex and only hex. A sentence pasted around it is the shape this
      // catches.
      expect(joinBlockedBecause('z' * 64), isNotNull);
      expect(joinBlockedBecause('${'a' * 60}, ok'), isNotNull);
    });

    test('a real one is let through', () {
      expect(joinBlockedBecause('a' * 64), isNull);
      expect(joinBlockedBecause('0123456789abcdef' * 4), isNull);
      // Including one that arrived shouting, since cleaning happens
      // first.
      expect(joinBlockedBecause('ABCDEF0123456789' * 4), isNull);
    });

    test('and the length it checks is the one the token has', () {
      expect(kInviteCodeLength, 64);
    });
  });
}
