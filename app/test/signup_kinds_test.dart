import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/core/surface.dart';
import 'package:iakauntan/src/features/auth/signup_kinds.dart';
import 'package:iakauntan/src/features/onboarding/onboarding_copy.dart';

/// Which answers to "What is this for?" a surface offers.
///
/// `0725`. Three answers, six switches, and the interesting cases are
/// all at the edges: one answer left is not a question, and none left
/// must not be a form that cannot be submitted.
SignupKinds on(
  Surface surface, {
  bool business = true,
  bool accountant = true,
  bool personal = true,
  bool businessApp = true,
  bool accountantApp = true,
  bool personalApp = true,
}) => signupKinds(
  surface,
  businessOnWeb: business,
  businessInTheApps: businessApp,
  accountantOnWeb: accountant,
  accountantInTheApps: accountantApp,
  personalOnWeb: personal,
  personalInTheApps: personalApp,
);

void main() {
  group('out of the box', () {
    test('all three, in the order they are drawn', () {
      expect(on(Surface.web).offered, [
        UseKind.business,
        UseKind.accountant,
        UseKind.personal,
      ]);
      expect(on(Surface.web).asks, isTrue);
    });

    test('and the same in both apps', () {
      for (final surface in [Surface.android, Surface.ios]) {
        expect(on(surface).offered, hasLength(3), reason: '$surface');
      }
    });
  });

  group('a surface reads its own switches', () {
    test('the web reads the web ones', () {
      final kinds = on(Surface.web, accountant: false, accountantApp: true);
      expect(kinds.offered, isNot(contains(UseKind.accountant)));
    });

    test('and an app reads the app ones', () {
      // The point of six switches rather than three. A store listing
      // that describes a personal invoicing app should not offer to
      // open a practice inside the app while the website still does.
      final android = on(Surface.android, accountant: true, accountantApp: false);
      expect(android.offered, isNot(contains(UseKind.accountant)));
      final web = on(Surface.web, accountant: true, accountantApp: false);
      expect(web.offered, contains(UseKind.accountant));
    });

    test('iOS and Android share the app switches, not the web ones', () {
      final off = on(Surface.ios, business: true, businessApp: false);
      expect(off.offered, isNot(contains(UseKind.business)));
    });

    test('a desktop build counts as the web', () {
      // There is no desktop build. Named rather than folded in so that
      // a rule about app stores does not silently become a rule about
      // a binary nobody ships — the same call `passkeyOffered` makes.
      expect(
        on(Surface.desktop, business: false, businessApp: true).offered,
        isNot(contains(UseKind.business)),
      );
    });
  });

  group('how many answers are left', () {
    test('two is still a question', () {
      final kinds = on(Surface.web, accountant: false);
      expect(kinds.offered, [UseKind.business, UseKind.personal]);
      expect(kinds.asks, isTrue);
    });

    test('one is not a question, and is what gets registered', () {
      // A segmented bar with a single segment is a button that cannot
      // be pressed and cannot be unpressed, and it invites somebody to
      // hunt for the options that are not there.
      final kinds = on(Surface.web, business: false, personal: false);
      expect(kinds.offered, [UseKind.accountant]);
      expect(kinds.asks, isFalse);
      expect(kinds.chosen, UseKind.accountant);
    });

    test('and none falls back to the individual, asking nothing', () {
      // NOT a form that cannot be submitted. An operator who switched
      // all three off has said what they want the form to BE, not that
      // they want no form — and the individual is the answer that needs
      // nothing else to be true: no SSM number, no registered name, no
      // paid module.
      final kinds = on(
        Surface.web,
        business: false,
        accountant: false,
        personal: false,
      );
      expect(kinds.offered, isEmpty);
      expect(kinds.asks, isFalse);
      expect(kinds.chosen, UseKind.personal);
    });

    test('none in the apps does not change the website', () {
      final app = on(
        Surface.ios,
        businessApp: false,
        accountantApp: false,
        personalApp: false,
      );
      expect(app.offered, isEmpty);
      expect(app.chosen, UseKind.personal);
      expect(on(Surface.web).offered, hasLength(3));
    });
  });

  group('what actually gets registered', () {
    test('what somebody picked, when it is still on offer', () {
      final kinds = on(Surface.web);
      expect(settledUse(kinds, UseKind.accountant), UseKind.accountant);
    });

    test('and not what they picked once it is withdrawn', () {
      // The form starts on `business` whether or not business is
      // offered here, and the payload is re-read while the form is
      // open. Registering somebody as a kind the platform has
      // withdrawn is worse than moving them.
      final kinds = on(Surface.web, business: false);
      expect(settledUse(kinds, UseKind.business), UseKind.accountant);
    });

    test('with nothing on offer at all, an individual', () {
      final kinds = on(
        Surface.web,
        business: false,
        accountant: false,
        personal: false,
      );
      expect(settledUse(kinds, UseKind.business), UseKind.personal);
      expect(settledUse(kinds, UseKind.accountant), UseKind.personal);
    });
  });
}
