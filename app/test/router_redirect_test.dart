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

  test('no visitor can be sent round in a circle', () {
    // The assertion this file exists for. Every path, under every
    // combination of what can be known, followed until it settles.
    const paths = [
      '/',
      '/welcome',
      '/signin',
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
                );
                if (next == null) break;
                expect(
                  seen.add(next),
                  isTrue,
                  reason:
                      'loop from $start: $seen — signedIn: $signedIn, '
                      'recovering: $recovering, hasOrg: $hasOrg, '
                      'admin: $admin',
                );
                at = next;
              }
              // And it settles quickly, not eventually.
              expect(
                seen.length,
                lessThanOrEqualTo(3),
                reason: 'from $start it took ${seen.length} hops: $seen',
              );
            }
          }
        }
      }
    }
  });

  _companyDoor();
}

/// `0333`. A company's own address opens on the sign-in form.
///
/// The bare domain's `/` is a shopfront for the product; a company that
/// paid for its own address did not buy one, and somebody who typed
/// `sinar.iakauntan.com` came looking for Sinar. Only `/` moves — a
/// signed-in visitor deeper in the app must not be bounced out of it.
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
        '/signin',
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
        '/signin',
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

    test('and /signin itself is not a loop', () {
      // The one mistake in this function that cannot be recovered from
      // outside: a redirect whose destination redirects back.
      expect(
        routeFor(
          path: '/signin',
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
