import 'package:flutter_test/flutter_test.dart';
import 'package:iakauntan/src/features/auth/demo_accounts.dart';
import 'package:iakauntan/src/features/landing/landing_content.dart';

/// Whether a stranger is offered a one-tap login into a demo company.
///
/// The failure worth catching is the permissive one, and it is silent:
/// the panel ships the demo password inside the bundle, and an owner
/// account that opens the whole company is one tap behind it. So every
/// assertion below is about the closed state — the open one is a single
/// case and it is the last test in the file.
void main() {
  group('the four reasons not to show them', () {
    bool show({
      bool buildAllows = true,
      bool platformOffers = true,
      bool isSignUp = false,
      bool atCompanyDoor = false,
    }) => showDemoAccounts(
      buildAllows: buildAllows,
      platformOffers: platformOffers,
      isSignUp: isSignUp,
      atCompanyDoor: atCompanyDoor,
    );

    test('a build that did not ask for demo mode', () {
      // The outer gate, and the one no row can reopen: the password is
      // simply not in that bundle.
      expect(show(buildAllows: false), isFalse);
    });

    test('a platform that has not switched them on', () {
      expect(show(platformOffers: false), isFalse);
    });

    test('halfway through creating an account', () {
      expect(show(isSignUp: true), isFalse);
    });

    test("at a company's own address", () {
      expect(show(atCompanyDoor: true), isFalse);
    });

    test('and neither gate is sufficient on its own', () {
      // Both directions, because "the console switch is enough" and
      // "the build flag is enough" are two different bugs.
      expect(show(buildAllows: true, platformOffers: false), isFalse);
      expect(show(buildAllows: false, platformOffers: true), isFalse);
    });

    test('shown only when all four say yes', () {
      expect(show(), isTrue);
    });
  });

  group('what the payload says', () {
    test('a platform that has said nothing is not offering them', () {
      // The default that matters. A payload written before 0335 has no
      // answer at all, and no answer must not read as yes.
      expect(
        parseLandingContent(const {'brand': {}}).demoAccountsEnabled,
        isFalse,
      );
      expect(LandingContent.fallback.demoAccountsEnabled, isFalse);
    });

    test('and one that has said so is', () {
      expect(
        parseLandingContent(const {
          'brand': {'demo_accounts_enabled': true},
        }).demoAccountsEnabled,
        isTrue,
      );
    });

    test('read from brand, so an unpublished site still answers', () {
      // `page` is gated on publication; the sign-in screen is not. A
      // switch carried only in `page` would appear to work in the
      // console and do nothing at the front door.
      final content = parseLandingContent(const {
        'brand': {'demo_accounts_enabled': true},
      });
      expect(content.published, isFalse);
      expect(content.demoAccountsEnabled, isTrue);
    });

    test('and anything that is not a boolean is a no', () {
      // The column is not null, but a hand-written payload or an older
      // one can carry anything. Guessing yes is the expensive guess.
      for (final v in <Object?>[null, 'true', 1, {}]) {
        expect(
          parseLandingContent({
            'brand': {'demo_accounts_enabled': v},
          }).demoAccountsEnabled,
          isFalse,
          reason: '$v',
        );
      }
    });
  });
}
