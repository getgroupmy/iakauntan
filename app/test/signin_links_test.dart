/// The small print at the foot of the sign-in screen in the apps.
///
/// Three questions worth asserting, and they fail differently:
///
///   * WHICH SURFACE. "Separately for android and ios" is the request,
///     so a rule that answered one switch for both would satisfy every
///     casual reading and take a required link out of one store's build
///     on the day somebody switched on the other's.
///   * PUBLISHED. A link drawn for an unpublished page lands on "this
///     page has not been written yet", under the words "Privacy
///     Policy". Worse than no link, and the reason the six switches can
///     safely ship on.
///   * THE DEMO GATES. The demo password is compiled into the bundle.
///     The two new switches are ANDed onto the four that were already
///     there, and the assertion with teeth is that each of the four
///     still refuses on its own.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:iakauntan/src/core/surface.dart';
import 'package:iakauntan/src/features/auth/signin_links.dart';

void main() {
  const allPublished = {'terms', 'terms-of-service', 'privacy'};

  List<String> slugs({
    required Surface surface,
    Set<String> published = allPublished,
    bool termsIos = true,
    bool termsAndroid = true,
    bool tosIos = true,
    bool tosAndroid = true,
    bool privacyIos = true,
    bool privacyAndroid = true,
  }) => signinFooterLinks(
    surface: surface,
    published: published,
    termsIos: termsIos,
    termsAndroid: termsAndroid,
    termsOfServiceIos: tosIos,
    termsOfServiceAndroid: tosAndroid,
    privacyIos: privacyIos,
    privacyAndroid: privacyAndroid,
  ).map((l) => l.slug).toList();

  group('which links an app draws', () {
    test('all three, in the order they are read', () {
      expect(slugs(surface: Surface.ios), [
        'terms',
        'terms-of-service',
        'privacy',
      ]);
      expect(slugs(surface: Surface.android), [
        'terms',
        'terms-of-service',
        'privacy',
      ]);
    });

    test('and each one is named the way the console names it', () {
      final links = signinFooterLinks(
        surface: Surface.ios,
        published: allPublished,
        termsIos: true,
        termsAndroid: true,
        termsOfServiceIos: true,
        termsOfServiceAndroid: true,
        privacyIos: true,
        privacyAndroid: true,
      );
      expect(links.map((l) => l.label), [
        'Terms of Use',
        'Terms of Service',
        'Privacy Policy',
      ]);
    });

    test('the browser draws none of them', () {
      // Not an omission. The website's own footer carries all three on
      // every page, including the page the form is on, and a second row
      // of them under the button is the same three links twice.
      expect(slugs(surface: Surface.web), isEmpty);
      expect(slugs(surface: Surface.desktop), isEmpty);
    });
  });

  group('separately, which is the whole request', () {
    test('turning the privacy link off on iOS leaves Android alone', () {
      expect(
        slugs(surface: Surface.ios, privacyIos: false),
        ['terms', 'terms-of-service'],
      );
      expect(slugs(surface: Surface.android, privacyIos: false), [
        'terms',
        'terms-of-service',
        'privacy',
      ]);
    });

    test('and the other way round', () {
      expect(slugs(surface: Surface.android, privacyAndroid: false), [
        'terms',
        'terms-of-service',
      ]);
      expect(slugs(surface: Surface.ios, privacyAndroid: false), [
        'terms',
        'terms-of-service',
        'privacy',
      ]);
    });

    test('every document has its own pair, not a shared one', () {
      // The failure this catches: six switches wired to three, or to
      // two. Each one is turned off alone and only its own link goes.
      expect(slugs(surface: Surface.ios, termsIos: false), [
        'terms-of-service',
        'privacy',
      ]);
      expect(slugs(surface: Surface.ios, tosIos: false), ['terms', 'privacy']);
      expect(slugs(surface: Surface.android, termsAndroid: false), [
        'terms-of-service',
        'privacy',
      ]);
      expect(slugs(surface: Surface.android, tosAndroid: false), [
        'terms',
        'privacy',
      ]);
    });
  });

  group('and only where there is something to read', () {
    test('an unpublished page is not linked, whatever the switch says', () {
      expect(
        slugs(surface: Surface.ios, published: const {'terms'}),
        ['terms'],
      );
      expect(slugs(surface: Surface.android, published: const {}), isEmpty);
    });

    test('which is why the switches can ship on', () {
      // The argument in one assertion: every switch on, nothing
      // published, nothing drawn. A fresh deployment is offered
      // nothing, so shipping these off would only have meant a second
      // switch to find after pressing Publish.
      expect(slugs(surface: Surface.ios, published: const {}), isEmpty);
    });
  });

  group('the way to the demo page', () {
    bool offered({
      Surface surface = Surface.android,
      bool buildAllows = true,
      bool platformOffers = true,
      bool onIos = true,
      bool onAndroid = true,
      bool isSignUp = false,
      bool atCompanyDoor = false,
    }) => demoPageOffered(
      surface: surface,
      buildAllows: buildAllows,
      platformOffers: platformOffers,
      onIos: onIos,
      onAndroid: onAndroid,
      isSignUp: isSignUp,
      atCompanyDoor: atCompanyDoor,
    );

    test('offered in an app with everything on', () {
      expect(offered(surface: Surface.android), isTrue);
      expect(offered(surface: Surface.ios), isTrue);
    });

    test('and never in a browser, which keeps the panel instead', () {
      expect(offered(surface: Surface.web), isFalse);
      expect(offered(surface: Surface.desktop), isFalse);
    });

    test('per platform, like everything else here', () {
      expect(offered(surface: Surface.ios, onIos: false), isFalse);
      expect(offered(surface: Surface.android, onIos: false), isTrue);
      expect(offered(surface: Surface.android, onAndroid: false), isFalse);
      expect(offered(surface: Surface.ios, onAndroid: false), isTrue);
    });

    test('and every older gate still refuses on its own', () {
      // The assertion that matters. These two switches are ADDED to the
      // chain in front of a password that ships inside the bundle; a
      // version that read them INSTEAD of the older gates would pass
      // every test above and hand out a seeded owner account on a build
      // that never asked for demo mode.
      expect(offered(buildAllows: false), isFalse, reason: 'DEMO_MODE off');
      expect(offered(platformOffers: false), isFalse, reason: 'console off');
      expect(offered(isSignUp: true), isFalse, reason: 'mid-registration');
      expect(offered(atCompanyDoor: true), isFalse, reason: "a company's own");
    });
  });

  group('and the panel the browser keeps', () {
    test('drawn on the web with the four older gates satisfied', () {
      expect(
        demoPanelOffered(
          surface: Surface.web,
          buildAllows: true,
          platformOffers: true,
          isSignUp: false,
          atCompanyDoor: false,
        ),
        isTrue,
      );
    });

    test('and not in an app, which has the link instead', () {
      // Both, and never both at once: twelve rows under the form on a
      // phone is what the link exists to avoid.
      for (final surface in [Surface.ios, Surface.android]) {
        expect(
          demoPanelOffered(
            surface: surface,
            buildAllows: true,
            platformOffers: true,
            isSignUp: false,
            atCompanyDoor: false,
          ),
          isFalse,
          reason: '$surface',
        );
      }
    });

    test('and the old gates are still the old gates', () {
      expect(
        demoPanelOffered(
          surface: Surface.web,
          buildAllows: false,
          platformOffers: true,
          isSignUp: false,
          atCompanyDoor: false,
        ),
        isFalse,
      );
      expect(
        demoPanelOffered(
          surface: Surface.web,
          buildAllows: true,
          platformOffers: false,
          isSignUp: false,
          atCompanyDoor: false,
        ),
        isFalse,
      );
    });
  });
}
