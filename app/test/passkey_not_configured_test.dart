import 'package:flutter_test/flutter_test.dart';
import 'package:iakauntan/src/features/auth/passkey.dart';
import 'package:iakauntan/src/features/auth/passkey_native.dart'
    show passkeySentenceFor;
import 'package:passkeys/exceptions.dart';

/// A site that has not deployed its association files, told apart from
/// a device that refused.
///
/// Reported from an iPhone and from an Android, on the sign-in form and
/// again on the Settings card: a red banner reading "This app is not set
/// up for passkeys on this system yet". It is the correct message and it
/// was being shown in the wrong register and at the wrong moment.
///
/// Nothing is wrong with the phone, the account, or the person reading
/// it. Two files have to be served from `/.well-known/` on the same
/// origin -- `assetlinks.json` on Android and
/// `apple-app-site-association` on iOS -- and neither exists: there is
/// no `app/web/.well-known/` directory in this repository, deliberately,
/// because `assetlinks.json` needs the Play App Signing certificate's
/// SHA-256 and the Apple file needs the team ID, and `docs/passkeys.md`
/// argues that a placeholder is worse than nothing. Until somebody
/// deploys them with the real values, every passkey press on a phone
/// ends here.
///
/// So: a plain note rather than a red one, the button withdrawn rather
/// than left to fail again, and -- on the sign-in screen -- the captcha
/// token no longer spent on a press that cannot succeed.
void main() {
  group('the classifier', () {
    test('recognises the sentence the platform actually raises', () {
      // THE DRIFT GUARD, and the reason the sentence is a constant. The
      // classifier compares against `passkeyDomainNotAssociated`; if
      // `_sentenceFor` ever stops returning exactly that -- somebody
      // improving the wording in one place -- this fails here rather
      // than silently turning the note red again on a phone nobody is
      // testing on.
      expect(
        passkeySentenceFor(
          DomainNotAssociatedException(
            'iakauntan.com is not associated with this application',
          ),
        ),
        passkeyDomainNotAssociated,
      );
      expect(passkeyNotSetUpHere(passkeyDomainNotAssociated), isTrue);
    });

    test('does not recognise any of the other refusals', () {
      // Each of these IS a fault of the device or the account, and each
      // keeps its red banner and its button. Collapsing them into "not
      // set up" would tell somebody with no Google account signed in to
      // go and talk to their administrator.
      for (final error in <Object>[
        NoCredentialsAvailableException(),
        MissingGoogleSignInException(),
        SyncAccountNotAvailableException(),
        DeviceNotSupportedException(),
      ]) {
        final said = passkeySentenceFor(error);
        expect(
          passkeyNotSetUpHere(said),
          isFalse,
          reason: '$error said: $said',
        );
      }
    });

    test('null is not a configuration state', () {
      // A dismissed prompt carries no message. It must not be read as
      // "the site is broken" and take the button away.
      expect(passkeyNotSetUpHere(null), isFalse);
    });

    test('an empty message is not one either', () {
      expect(passkeyNotSetUpHere(''), isFalse);
    });

    test('a message that merely mentions the words is not one', () {
      // Matched on equality against the constant, not on a substring,
      // so a server-supplied message quoting it cannot switch the card
      // into its configuration state.
      expect(
        passkeyNotSetUpHere('Error: $passkeyDomainNotAssociated'),
        isFalse,
      );
    });
  });

  group('the sentence itself', () {
    test('says whose problem it is', () {
      // The person reading it can do nothing about it, and a message
      // that does not say so gets read as "your phone is broken".
      expect(passkeyDomainNotAssociated, contains('setting on the site'));
      expect(
        passkeyDomainNotAssociated,
        contains('rather than anything you have done'),
      );
    });

    test('and says what to do in the meantime', () {
      expect(passkeyDomainNotAssociated, contains('password'));
    });
  });
}
