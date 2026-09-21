import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/core/router.dart';

/// Where a visitor ends up, and that they end up somewhere.
///
/// This is the one rule in the app whose mistakes are unrecoverable
/// from the outside. A wrong screen is a bug; a redirect that returns a
/// path which redirects back is a product that will not open at all,
/// and nothing in the code says so — the loop only appears in a
/// browser, on the address everybody uses.
///
/// So the last test here is not about any particular route. It walks
/// every path this file knows about, under every combination of what
/// can be known about the visitor, and follows the redirect until it
/// settles. If it does not settle, the site is bricked.
void main() {
  String? go(
    String path, {
    bool signedIn = false,
    bool recovering = false,
    bool? hasOrg = true,
    bool? isPlatformAdmin = false,
  }) => routeFor(
    path: path,
    signedIn: signedIn,
    recovering: recovering,
    hasOrg: hasOrg,
    isPlatformAdmin: isPlatformAdmin,
  );

  group('the address on the business card', () {
    test('a stranger typing it gets the front page', () {
      expect(go('/'), isNull);
    });

    test('and so does somebody already signed in', () {
      // The change. It used to post them straight into their books,
      // which meant the product had no front page for anybody who had
      // ever logged in — including the person who owns it, trying to
      // look at what they just published.
      expect(go('/', signedIn: true), isNull);
    });

    test('even mid password recovery, and with no company yet', () {
      // Both of those force every *other* route somewhere. The front
      // page is a public page: there is nothing on it to protect.
      expect(go('/', signedIn: true, recovering: true), isNull);
      expect(go('/', signedIn: true, hasOrg: false), isNull);
      expect(go('/', signedIn: true, hasOrg: null), isNull);
    });

    test('the old address still lands on it', () {
      // `/welcome` was the front page for a while and links to it
      // exist. One redirect, not a second copy of the page.
      expect(go('/welcome'), '/');
      expect(go('/welcome', signedIn: true), '/');
    });
  });

  group('pressing the way in', () {
    test('signed out, it asks for a password', () {
      expect(go('/signin'), isNull);
    });

    test('signed in, it goes straight to the books', () {
      // What "Sign in" means to somebody who already is. The button on
      // the landing page is the same button either way; only the
      // password step differs.
      expect(go('/signin', signedIn: true), '/dashboard');
    });

    test('and the books are not the front page any more', () {
      expect(go('/dashboard', signedIn: true), isNull);
    });
  });

  group('what a signed-out visitor may reach', () {
    test('the three token pages, without an account', () {
      // A director signing one resolution, a customer opening their own
      // invoice, somebody at a table with a QR sticker. None of them
      // will sign up to an accounting system first.
      for (final path in ['/sign/abc', '/share/abc', '/menu/abc']) {
        expect(go(path), isNull, reason: path);
      }
    });

    test('the terms, the privacy policy and the way to ask about them', () {
      // Somebody is asked to agree to these before they have an
      // account, which makes "sign in to read the terms" a circle.
      for (final path in ['/terms', '/privacy', '/contact']) {
        expect(go(path), isNull, reason: path);
      }
    });

    test('and they stay open at a company\'s own door too', () {
      // `/` there is the sign-in form. These three are not: a policy
      // is a policy whichever address it was reached from.
      for (final path in ['/terms', '/privacy', '/contact']) {
        expect(
          routeFor(
            path: path,
            signedIn: false,
            recovering: false,
            hasOrg: null,
            isPlatformAdmin: null,
            atCompanyDoor: true,
          ),
          isNull,
          reason: path,
        );
      }
    });

    test('and nothing else — everything else is the front page', () {
      for (final path in ['/dashboard', '/sales', '/settings', '/admin']) {
        expect(go(path), '/', reason: path);
      }
    });
  });

  group('the rest of the rule, unchanged', () {
    test('recovery outranks everything a session unlocks', () {
      // Redeeming a reset link signs the user in. Arriving at the books
      // with the forgotten password still in force is the failure.
      expect(
        go('/dashboard', signedIn: true, recovering: true),
        '/reset-password',
      );
      expect(go('/reset-password', signedIn: true, recovering: true), isNull);
    });

    test('an answer still loading holds the route rather than guessing', () {
      // Deciding without it is what sent an operator to onboarding and
      // left them there.
      expect(go('/sales', signedIn: true, hasOrg: null), isNull);
      expect(go('/sales', signedIn: true, isPlatformAdmin: null), isNull);
    });

    test('somebody with no company is sent to make one', () {
      expect(go('/sales', signedIn: true, hasOrg: false), '/onboarding');
      expect(go('/onboarding', signedIn: true, hasOrg: false), isNull);
    });

    test('except an operator, whose home is the console', () {
      expect(
        go('/sales', signedIn: true, hasOrg: false, isPlatformAdmin: true),
        '/admin',
      );
      for (final path in ['/admin/landing', '/onboarding', '/settings']) {
        expect(
          go(path, signedIn: true, hasOrg: false, isPlatformAdmin: true),
          isNull,
          reason: path,
        );
      }
    });

    test('and onboarding is done once there is a company', () {
      expect(go('/onboarding', signedIn: true), '/dashboard');
    });
  });

  group('what counts as the app', () {
    test('a phone is', () {
      for (final p in [TargetPlatform.android, TargetPlatform.iOS]) {
        debugDefaultTargetPlatformOverride = p;
        expect(runningInTheApp, isTrue, reason: '$p');
        debugDefaultTargetPlatformOverride = null;
      }
    });

    test('and a desktop build is not', () {
      // Named as the two platforms rather than as "not web", so a
      // Linux or Windows build keeps the front page. There is no
      // desktop build today; there is also no reason for one to lose a
      // page because of a rule about app stores.
      for (final p in [
        TargetPlatform.linux,
        TargetPlatform.macOS,
        TargetPlatform.windows,
      ]) {
        debugDefaultTargetPlatformOverride = p;
        expect(runningInTheApp, isFalse, reason: '$p');
        debugDefaultTargetPlatformOverride = null;
      }
    });

    // NOT ASSERTED, and worth saying so rather than leaving a gap that
    // looks like coverage: the `!kIsWeb` half of `runningInTheApp`.
    //
    // It is the half that matters most. Flutter web in Safari on an
    // iPhone answers `TargetPlatform.iOS` to `defaultTargetPlatform`
    // -- that getter is about which look and feel to adopt, not about
    // how the code was compiled -- so without `!kIsWeb` the shopfront
    // would disappear for every visitor on a phone browser, which is
    // most of them.
    //
    // `flutter test` runs on the VM, where `kIsWeb` is a const false
    // and the compiler folds the whole condition away. Removing it
    // here changes nothing that any test in this file can observe, and
    // a mutation run says so. What would catch it is `flutter test
    // --platform chrome`, which this repository does not run.
  });

  group('the app has no shopfront', () {
    String? app(
      String path, {
      bool signedIn = false,
      bool? hasOrg = true,
      bool atCompanyDoor = false,
      String? landing,
    }) => routeFor(
      path: path,
      signedIn: signedIn,
      recovering: false,
      hasOrg: hasOrg,
      isPlatformAdmin: false,
      nativeApp: true,
      atCompanyDoor: atCompanyDoor,
      landingRoute: landing,
    );

    test('so it opens at the sign-in form', () {
      // The whole request, in one line. On the web `/` is the landing
      // page and the form is one button away; nobody installs an
      // accounting system from an app store to read about accounting
      // systems.
      expect(app('/'), '/signin');
    });

    test('and the web still gets its front page', () {
      // The other half, and the one that would be quietly lost. This
      // is a redirect on the address everybody types.
      expect(go('/'), isNull);
      expect(go('/', signedIn: true), isNull);
    });

    test('the old address goes the same way and not through the new one', () {
      // `/welcome` redirects to `/` on the web, and on a phone that
      // would be a hop through a page that only exists to redirect
      // again. Said once.
      expect(app('/welcome'), '/signin');
    });

    test('signing out leaves somebody at the form rather than a shopfront', () {
      // On the web this answer is `/`. In the app there is no `/` to
      // be at, and answering `/` would send them through a marketing
      // page for the product they have open.
      expect(app('/dashboard'), '/signin');
      expect(app('/settings'), '/signin');
    });

    test('and it defers to the door rule rather than overriding it', () {
      // `atCompanyDoor` is a fact about a browser's address bar, and a
      // build in an app store has none -- `workspaceLookupProvider`
      // answers `platform` for a native build by construction, so this
      // combination does not arise today.
      //
      // Asserted anyway, and for what it says about the SHAPE of the
      // rule rather than about the case: the app's `/` is answered by
      // asking what the door itself answers, so if this app ever does
      // learn whose address it is, one rule decides and not two. A
      // flat `/signin` here would have been a second opinion that
      // silently outranked the first.
      expect(app('/', atCompanyDoor: true), '/login');
    });

    test('somebody already signed in reaches their books, not the form', () {
      // In one hop, which is the assertion. Answering `/signin` here
      // and letting that redirect on again put a platform operator
      // through four screens' worth of rebuilds -- `/`, `/signin`,
      // `/dashboard`, `/admin` -- and the sweep below refused it.
      expect(app('/', signedIn: true), '/dashboard');
      expect(app('/welcome', signedIn: true), '/dashboard');
      expect(app('/', signedIn: true, landing: '/pos'), '/pos');
    });

    test('and an operator with no company of their own reaches the console', () {
      // The case that found the extra hops. Platform staff belong to
      // no organization at all, so `/signin` answers `/dashboard` and
      // `/dashboard` answers `/admin` -- three screens on the web, and
      // four in the app until `/` stopped answering `/signin` and
      // started answering what `/signin` would have.
      //
      // Followed rather than asserted one step at a time, because the
      // thing that matters is where somebody who opens the app ends
      // up, not which rule did it.
      var at = '/';
      final seen = <String>{at};
      for (var hop = 0; hop < 5; hop++) {
        final next = routeFor(
          path: at,
          signedIn: true,
          recovering: false,
          hasOrg: false,
          isPlatformAdmin: true,
          nativeApp: true,
        );
        if (next == null) break;
        at = next;
        seen.add(at);
      }
      expect(at, '/admin');
      expect(seen, hasLength(lessThanOrEqualTo(3)), reason: '$seen');
    });

    test('and the form itself is left alone', () {
      // The rule is about `/`. A visitor who is already at the door
      // must not be moved, or the app opens on a screen it immediately
      // navigates away from.
      expect(app('/signin'), isNull);
    });

    test('the pages read before signing in are still reachable', () {
      // Terms, privacy and contact are linked from the form itself,
      // and a policy you have to sign in to read is not a policy. The
      // app rule must not swallow them.
      for (final path in ['/terms', '/privacy', '/contact']) {
        expect(app(path), isNull, reason: path);
        expect(app(path, signedIn: true), isNull, reason: path);
      }
    });

    test('and so are the four pages that need no account at all', () {
      // A director signing one resolution, a customer opening their
      // own invoice, a diner with a QR sticker. None of them has an
      // account and none of them is going to make one.
      for (final path in ['/sign/abc', '/share/abc', '/menu/abc',
                          '/tax-details/abc']) {
        expect(app(path), isNull, reason: path);
      }
    });
  });

  test('no visitor can be sent round in a circle', () {
    // The assertion this file exists for. Every path, under every
    // combination of what can be known, followed until it settles.
    const paths = [
      '/',
      '/welcome',
      '/signin',
      '/login',
      '/dashboard',
      '/sales',
      '/settings',
      '/onboarding',
      '/reset-password',
      '/admin',
      '/admin/landing',
      '/sign/abc',
      '/share/abc',
      '/menu/abc',
      '/terms',
      '/privacy',
      '/contact',
      '/nothing-like-this',
    ];
    for (final signedIn in [true, false]) {
      for (final recovering in [true, false]) {
        for (final hasOrg in [true, false, null]) {
          for (final admin in [true, false, null]) {
            // The app is swept too, and it is the surface most able to
            // brick itself: `/` is where the router starts and in the
            // app it is never a destination, so the rule that moves
            // somebody off it is exactly the shape of rule that can
            // send them round.
            for (final native in [true, false]) {
            for (final start in paths) {
              var at = start;
              final seen = <String>{at};
              for (var hop = 0; hop < 10; hop++) {
                final next = routeFor(
                  path: at,
                  signedIn: signedIn,
                  recovering: recovering,
                  hasOrg: hasOrg,
                  isPlatformAdmin: admin,
                  nativeApp: native,
                );
                if (next == null) break;
                expect(
                  seen.add(next),
                  isTrue,
                  reason:
                      'loop from $start: $seen — signedIn: $signedIn, '
                      'recovering: $recovering, hasOrg: $hasOrg, '
                      'admin: $admin, native: $native',
                );
                at = next;
              }
              // And it settles quickly, not eventually.
              expect(
                seen.length,
                lessThanOrEqualTo(3),
                reason: 'from $start it took ${seen.length} hops: $seen '
                    '(native: $native)',
              );
            }
            }
          }
        }
      }
    }
  });

  _companyDoor();
  _theTwoDoors();
}

/// `0333`. A company's own address opens on the sign-in form.
///
/// The bare domain's `/` is a shopfront for the product; a company that
/// paid for its own address did not buy one, and somebody who typed
/// `sinar.iakauntan.com` came looking for Sinar. Only `/` moves — a
/// signed-in visitor deeper in the app must not be bounced out of it.
///
/// The form it lands on is `/login` since `0348`, not `/signin`: same
/// screen, and a page of copy written for the people who work there
/// rather than for somebody deciding whether to buy an accounting
/// system. `_theTwoDoors` below is about which of the two an address
/// gets; this group is still about which addresses move at all.
void _companyDoor() {
  group('a company\'s own door', () {
    test('sends the front page to the sign-in form', () {
      expect(
        routeFor(
          path: '/',
          signedIn: false,
          recovering: false,
          hasOrg: null,
          isPlatformAdmin: null,
          atCompanyDoor: true,
        ),
        '/login',
      );
    });

    test('leaves the bare domain alone', () {
      expect(
        routeFor(
          path: '/',
          signedIn: false,
          recovering: false,
          hasOrg: null,
          isPlatformAdmin: null,
        ),
        isNull,
      );
    });

    test('does not bounce a signed-in visitor out of the app', () {
      expect(
        routeFor(
          path: '/dashboard',
          signedIn: true,
          recovering: false,
          hasOrg: true,
          isPlatformAdmin: false,
          atCompanyDoor: true,
        ),
        isNull,
      );
    });

    test('signing out lands on the sign-in form, not the front page', () {
      // The route somebody is on when they sign out is wherever they
      // were — the button does not navigate, the router re-decides.
      expect(
        routeFor(
          path: '/dashboard',
          signedIn: false,
          recovering: false,
          hasOrg: null,
          isPlatformAdmin: null,
          atCompanyDoor: true,
        ),
        '/login',
      );
    });

    test('and at the bare domain it still lands on the front page', () {
      expect(
        routeFor(
          path: '/dashboard',
          signedIn: false,
          recovering: false,
          hasOrg: null,
          isPlatformAdmin: null,
        ),
        '/',
      );
    });

    test('and the door it sends them to is not a loop', () {
      // The one mistake in this function that cannot be recovered from
      // outside: a redirect whose destination redirects back. `/signin`
      // at a company's address moves once, to `/login`, and `/login`
      // stays put — which is the pair `_theTwoDoors` walks in full.
      expect(
        routeFor(
          path: '/login',
          signedIn: false,
          recovering: false,
          hasOrg: null,
          isPlatformAdmin: null,
          atCompanyDoor: true,
        ),
        isNull,
      );
    });
  });
}

/// Two doors, and an address has exactly one of them.
///
/// `0348` gives a company's own address its own page of sign-in copy,
/// which means a second route drawing the same form. Two routes that
/// each redirect to the other is the one mistake here that bricks the
/// product rather than merely getting it wrong, so the last test walks
/// them.
///
/// The hold is the other half. `atCompanyDoor` is false while the host
/// lookup is in flight, and a rule that acts on it before the answer
/// lands sends a company's own staff to the platform's door and moves
/// them to theirs a moment later — with the wrong heading over the form
/// in between, which is exactly the flicker the rest of this session
/// went to some trouble to remove.
void _theTwoDoors() {
  group('two doors, one to an address', () {
    String? at(
      String path, {
      bool door = false,
      bool known = true,
      bool signedIn = false,
    }) => routeFor(
      path: path,
      signedIn: signedIn,
      recovering: false,
      hasOrg: true,
      isPlatformAdmin: false,
      atCompanyDoor: door,
      doorKnown: known,
    );

    test("a company's address opens its own door", () {
      expect(at('/signin', door: true), '/login');
      expect(at('/login', door: true), isNull);
    });

    test('and the bare domain opens ours', () {
      expect(at('/login'), '/signin');
      expect(at('/signin'), isNull);
    });

    test("and `/` at a company's address is the form, not a shopfront", () {
      expect(at('/', door: true), '/login');
      expect(at('/'), isNull);
    });

    test('signing out leaves you at the door you came in by', () {
      expect(at('/dashboard', door: true), '/login');
      expect(at('/dashboard'), '/');
    });

    test('neither door moves anybody while the lookup is in flight', () {
      expect(at('/login', known: false), isNull);
      expect(at('/signin', known: false), isNull);
    });

    test('and a session at either one goes to the books', () {
      expect(at('/login', signedIn: true, door: true), '/dashboard');
      expect(at('/signin', signedIn: true), '/dashboard');
      // Held for the reason the signed-out pair are: the books are a
      // different screen at a confined address.
      expect(at('/login', signedIn: true, known: false), isNull);
    });

    test('and neither one leads to the other and back', () {
      for (final door in [true, false]) {
        for (final known in [true, false]) {
          for (final signedIn in [true, false]) {
            for (final start in ['/', '/signin', '/login', '/dashboard']) {
              var here = start;
              final seen = <String>{here};
              for (var hop = 0; hop < 10; hop++) {
                final next =
                    at(here, door: door, known: known, signedIn: signedIn);
                if (next == null) break;
                expect(
                  seen.add(next),
                  isTrue,
                  reason: 'loop from $start: $seen — door: $door, '
                      'known: $known, signedIn: $signedIn',
                );
                here = next;
              }
            }
          }
        }
      }
    });
  });

  // ---------------------------------------------------------------------
  // Where a person lands, once they have said where they want to (0527)
  // ---------------------------------------------------------------------
  group('the landing page somebody chose', () {
    String? at(String path, {String? landing, String? confinedTo}) => routeFor(
      path: path,
      signedIn: true,
      recovering: false,
      hasOrg: true,
      isPlatformAdmin: false,
      confinedTo: confinedTo,
      confinedAllows: confinedTo == null ? const {} : const {'pos'},
      moduleHeld: confinedTo == null ? null : true,
      landingRoute: landing,
    );

    test('signing in opens the page they asked for', () {
      expect(at('/signin', landing: '/todos'), '/todos');
      expect(at('/login', landing: '/pos'), '/pos');
    });

    test('and the dashboard for somebody who has never chosen', () {
      expect(at('/signin'), '/dashboard');
    });

    test('a preference that never arrives does not trap anybody', () {
      // The failure this guards against is the bad one: holding the
      // route until the preference loads turns a failed read -- an
      // error, a dropped connection -- into a sign-in screen nobody can
      // leave. Null means the dashboard, which is what everybody got
      // before the preference existed.
      expect(at('/signin', landing: null), '/dashboard');
      expect(at('/login', landing: null), '/dashboard');
    });

    test('but a confined address still opens what it is pinned to', () {
      // The address wins over the person. A tablet on a counter goes to
      // the till whatever its user prefers, because that was chosen by
      // whoever set the device up.
      expect(at('/dashboard', landing: '/todos', confinedTo: '/pos'), '/pos');
    });
  });
}