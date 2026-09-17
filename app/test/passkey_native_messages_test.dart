@TestOn('vm')
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:passkeys/exceptions.dart';

import 'package:iakauntan/src/features/auth/passkey_native.dart';

/// What a phone says when the passkey does not work.
///
/// The one testable part of `passkey_native.dart`. Everything else in
/// that file needs Credential Manager or `ASAuthorization` and cannot
/// be exercised on a machine, which is exactly why this part is split
/// out and pure: it is the half that decides what somebody READS, and
/// getting it wrong is silent.
///
/// The failure this guards against is the one the whole file exists
/// for. A phone whose domain is not associated — no `assetlinks.json`,
/// no `apple-app-site-association`, or one that names a different
/// signing certificate — refuses the ceremony outright, and from the
/// outside that is a button that does nothing at all. Silent, on the
/// sign-in screen, for every user, and indistinguishable from the app
/// being broken.
///
/// So every branch here has to produce a sentence, and the sentence
/// has to say who can act on it — because in most of these cases it is
/// not the person reading it.
void main() {
  group('when the platform refuses', () {
    test('an unassociated domain says it is the site, not you', () {
      // The big one. `DomainNotAssociatedException` is a build
      // configuration mistake, and somebody holding a phone can do
      // nothing whatever about it. The worst outcome is that they
      // conclude they typed something wrong.
      final said = passkeySentenceFor(
        DomainNotAssociatedException('rpId mismatch'),
      ).toLowerCase();
      expect(said, contains('not set up'));
      expect(said, contains('rather than anything you have done'));
      // And it leaves them a way in, which is the whole difference
      // between a report and a dead end.
      expect(said, contains('password'));
    });

    test('and never repeats the platform\'s own words', () {
      // `rpId mismatch` is true, useless and alarming. It must not
      // reach the screen.
      expect(
        passkeySentenceFor(DomainNotAssociatedException('rpId mismatch')),
        isNot(contains('rpId')),
      );
    });

    test('an empty keychain says so rather than sounding broken', () {
      // Not a fault. The button is drawn for everybody, and somebody
      // who has never enrolled cannot tell an empty keychain from a
      // broken app — so this one says what to go and do.
      final said = passkeySentenceFor(
        NoCredentialsAvailableException(),
      ).toLowerCase();
      expect(said, contains('no passkey saved'));
      expect(said, contains('settings'));
    });

    test('the two Android account problems are the ones you can fix', () {
      // The only branches whose remedy is in the reader's own hands,
      // and the only ones that give an instruction.
      expect(
        passkeySentenceFor(MissingGoogleSignInException()).toLowerCase(),
        contains('google account'),
      );
      expect(
        passkeySentenceFor(SyncAccountNotAvailableException()).toLowerCase(),
        contains('google password manager'),
      );
    });

    test('a timeout says to try again, because that is what to do', () {
      expect(
        passkeySentenceFor(TimeoutException('waited')).toLowerCase(),
        contains('try again'),
      );
    });

    test('a device that cannot do this at all says so', () {
      for (final e in [
        DeviceNotSupportedException(),
        PasskeyUnsupportedException('old'),
      ]) {
        expect(
          passkeySentenceFor(e).toLowerCase(),
          contains('cannot use passkeys'),
          reason: '$e',
        );
      }
    });

    test('malformed options are ours to fix and say so', () {
      // The server sent a challenge that is not base64url. Nobody
      // pressing a button caused that.
      final said = passkeySentenceFor(
        MalformedBase64UrlChallenge(),
      ).toLowerCase();
      expect(said, contains('fault on the site'));
    });

    test('and anything at all still gets a sentence', () {
      // The branch that matters most in a year's time: the plugin can
      // raise things this file has never heard of, and the default
      // must not be silence or a stack trace.
      for (final e in <Object>[
        UnhandledAuthenticatorException('android-unhandled-7', 'x', null),
        Exception('something new'),
        StateError('or this'),
      ]) {
        final said = passkeySentenceFor(e);
        expect(said, isNotEmpty, reason: '$e');
        expect(said.toLowerCase(), contains('password'), reason: '$e');
      }
    });

    test('every sentence is something a person could read out', () {
      // No exception type names, no error codes, no camelCase. This is
      // the check that catches a new branch pasted in from a log.
      final all = <Object>[
        DomainNotAssociatedException('rpId mismatch'),
        NoCredentialsAvailableException(),
        MissingGoogleSignInException(),
        SyncAccountNotAvailableException(),
        DeviceNotSupportedException(),
        PasskeyUnsupportedException('old'),
        TimeoutException('waited'),
        MalformedBase64UrlChallenge(),
        Exception('something new'),
      ];
      for (final e in all) {
        final said = passkeySentenceFor(e);
        expect(said, isNot(contains('Exception')), reason: '$e');
        expect(said, endsWith('.'), reason: '$e');
        expect(said.length, greaterThan(30), reason: '$e');
      }
    });
  });
}
