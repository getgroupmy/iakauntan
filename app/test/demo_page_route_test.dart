/// `/demo`, and who is let through it.
///
/// `0653` added a page of one-tap demo logins, linked from the foot of
/// the sign-in screen in the apps. Its route has to answer two
/// questions that no other public path answers the same way, which is
/// why it is not on `publicSitePageSlugs`:
///
///   * SIGNED OUT is the whole of who it is for, and the ordinary rule
///     for a signed-out visitor sends a native build to `/signin` and a
///     browser to the front page. That rule is exactly what made
///     `/terms-of-service` unreachable in `0651`, found only after it
///     had been linked from three places — so this is asserted rather
///     than assumed.
///   * SIGNED IN is not. Pressing "look around a demo" with an account
///     already is asking to become somebody else, and the picker would
///     do it: these are ordinary auth users with ordinary roles. They
///     go to their own books instead.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:iakauntan/src/core/router.dart';

void main() {
  String? go(
    String path, {
    bool signedIn = false,
    bool recovering = false,
    bool? hasOrg = true,
    bool? isPlatformAdmin = false,
    bool atCompanyDoor = false,
    bool nativeApp = false,
    bool doorKnown = true,
  }) => routeFor(
    path: path,
    signedIn: signedIn,
    recovering: recovering,
    hasOrg: hasOrg,
    isPlatformAdmin: isPlatformAdmin,
    atCompanyDoor: atCompanyDoor,
    nativeApp: nativeApp,
    doorKnown: doorKnown,
  );

  group('a visitor with no session', () {
    test('is let through', () {
      expect(go('/demo'), isNull);
    });

    test('in the app, which is the only place the link is drawn', () {
      // The one that would have been broken. Without its own clause
      // the signed-out rule answers `/signin` for a native build, and
      // the link at the foot of the form would bounce straight back to
      // the form it was under.
      expect(go('/demo', nativeApp: true), isNull);
    });

    test('and before the door lookup has answered', () {
      // `doorKnown` false is an ordinary moment on every load, and a
      // page that is only reachable once a network call lands is a page
      // that sometimes is not.
      expect(go('/demo', doorKnown: false, hasOrg: null), isNull);
    });
  });

  group('a visitor who already has one', () {
    test('goes to their books rather than to a demo company', () {
      expect(go('/demo', signedIn: true), '/dashboard');
    });

    test('and a reset link still outranks it', () {
      // Recovery is checked first for the reason it is checked first
      // everywhere: redeeming the link signs somebody in, and landing
      // anywhere but the password form leaves the forgotten password
      // in force.
      expect(
        go('/demo', signedIn: true, recovering: true),
        '/reset-password',
      );
    });

    test('and the decision is held while the door is unknown', () {
      // Not a hop to the dashboard and back. The same hold `/signin`
      // and `/login` take, for the same reason.
      expect(go('/demo', signedIn: true, doorKnown: false), isNull);
    });
  });

  test('and it is not on the list of public site pages', () {
    // A document and a way in are different things. `/demo` signs
    // somebody in; the four on that list are read and nothing else,
    // and folding this into them would have made "a stranger may read
    // this" mean "a stranger may sign in here".
    expect(publicPathNeedsNoSession('/demo'), isFalse);
  });

  test('a path that merely starts the same way is not let through', () {
    // The control. Without it a clause written with `startsWith` would
    // pass everything above and wave `/demonstration-of-the-ledger`,
    // or anything else beginning `/demo`, past the sign-in redirect.
    expect(go('/demo-company'), isNot(isNull));
    expect(go('/demos'), isNot(isNull));
  });
}
