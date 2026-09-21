import 'package:flutter_test/flutter_test.dart';
import 'package:iakauntan/src/features/auth/reset_cooldown.dart';
import 'package:iakauntan/src/features/landing/landing_content.dart';

/// Continue with Google — 0645.
///
/// README said OAuth "needs a provider's credentials in the dashboard",
/// which reads as code waiting on a secret. There was no OAuth code at
/// all: nothing called `signInWithOAuth`, named an `OAuthProvider` or
/// drew a provider button.
///
/// The rule worth asserting is not that a button exists. It is the
/// SECOND wall, which no amount of dashboard configuration clears:
/// `signInWithOAuth` returns through a `redirectTo`, and neither
/// platform registers a URL scheme, so on a phone the provider has
/// nowhere to send somebody back to.
void main() {
  group('where the button is drawn', () {
    test('on the web, once the operator turns it on', () {
      expect(googleButtonShown(offered: true, onWeb: true), isTrue);
    });

    test('and nowhere until they do', () {
      expect(googleButtonShown(offered: false, onWeb: true), isFalse);
    });

    test('never on a phone, however the switch is set', () {
      // The one that matters. `AndroidManifest.xml` registers no
      // scheme in its intent filters and `Info.plist` has no
      // `CFBundleURLSchemes`, so the provider has nowhere to return
      // to — the button would be a way out of the app with no way
      // back in. A platform file, not a line of Dart.
      expect(googleButtonShown(offered: true, onWeb: false), isFalse);
      expect(googleButtonShown(offered: false, onWeb: false), isFalse);
    });
  });

  group('the switch comes off the wire', () {
    LandingContent brandWith(Map<String, dynamic> brand) =>
        parseLandingContent({'page': <String, dynamic>{}, 'brand': brand});

    test('as true only when the column says so', () {
      expect(brandWith({'signin_show_google': true}).signinShowGoogle, isTrue);
    });

    test('and a payload without it is off', () {
      // Every deployment until an operator turns it on, and the shape
      // of a client talking to a project that has not run 0645.
      expect(brandWith({}).signinShowGoogle, isFalse);
      expect(
        brandWith({'signin_show_google': null}).signinShowGoogle,
        isFalse,
      );
    });

    test('and on a platform that has published no site', () {
      // `parseLandingContent` has TWO constructions — one for a
      // published site and one for the unpublished case `0316`
      // describes, where the brand still has to survive. The
      // unpublished one is the ordinary state of a fresh platform, and
      // it is the one an operator turning this switch on for the first
      // time is looking at.
      //
      // A mutant that hardcoded the switch to false in that branch
      // survived the whole file until this went in, because every
      // other case here passes a `page` and takes the other branch.
      final unpublished = parseLandingContent({
        'brand': {'signin_show_google': true},
      });

      expect(unpublished.published, isFalse);
      expect(unpublished.signinShowGoogle, isTrue);
    });

    test('and it does not ship on', () {
      // The default the constructor carries, which is what a screen
      // built before any payload arrives reads.
      expect(const LandingContent(published: false).signinShowGoogle, isFalse);
    });
  });

  group('what it says when the provider refuses', () {
    test('it names the dashboard, which GoTrue never does', () {
      // The first refusal everybody meets is the provider not being
      // enabled. GoTrue's own sentence names neither a dashboard nor a
      // provider, so somebody reads an error about a "provider" and
      // has nowhere to go with it.
      final said = googleProblem('Unsupported provider: provider is not enabled');

      expect(said, contains('Supabase dashboard'));
      expect(said, contains('Providers'));
      expect(said, contains('client ID and secret'));
    });

    test('and keeps what the server said', () {
      // A refusal this does not know about is better read than
      // replaced.
      expect(
        googleProblem('Something nobody has seen before'),
        startsWith('Something nobody has seen before'),
      );
    });

    test('and says something useful when the server said nothing', () {
      // The non-AuthException path: a network failure, a popup
      // blocked. An empty sentence would be a button that fails
      // silently, which is what every switch in this file exists to
      // stop.
      for (final nothing in [null, '', '   ']) {
        expect(googleProblem(nothing), contains('Supabase dashboard'));
        expect(googleProblem(nothing).trim(), isNotEmpty);
      }
    });

    test('and does not begin with a stray full stop', () {
      // `'$said. $advice'` with an empty `said` would.
      expect(googleProblem(null), isNot(startsWith('.')));
      expect(googleProblem('  '), isNot(startsWith('.')));
    });
  });
}
