/// The small print at the foot of the sign-in screen in the apps.
///
/// Asked for as: at the bottom of the main sign-in screen on iOS and
/// Android, link Terms of Use, Terms of Service and Privacy Policy, and
/// a way to a page of demo logins beside them — each with its own
/// switch per platform in the console.
///
/// ## Why the apps and not the browser
///
/// The website carries all three in the landing page's footer, on every
/// page including the one the sign-in form is on. The apps have no
/// footer and no landing page — `0639` opens a native build at the form
/// rather than at the shopfront — so in an app these three documents
/// were linked from the consent line under the REGISTER button and
/// nowhere else. Somebody signing in rather than registering could not
/// reach any of them.
///
/// That is a review problem as much as a courtesy one. Both stores ask
/// where a build's privacy policy is, and a build whose only link to it
/// sits under a button on a form the reviewer did not open is a build
/// that appears not to have one.
///
/// ## Two gates, and the published one is not a switch
///
/// A link is drawn when the console's switch for this platform is on
/// AND the page behind it is published. The second half is not a second
/// opinion about the same question: `site_pages()` withholds the body
/// of an unpublished page, so the link would land on "this page has not
/// been written yet". Under the words "Privacy Policy" that is worse
/// than no link.
///
/// Which is also why all six switches ship ON, against the habit every
/// switch added since `0579` follows. They offer nothing on a fresh
/// deployment — nothing is published — so shipping them off would only
/// mean that an operator who publishes their privacy policy then has to
/// find a second switch before anyone can see it.
library;

import '../../core/surface.dart';
import 'demo_accounts.dart';

/// One link at the foot of the form.
typedef SigninLink = ({String slug, String label});

/// What each of the three is called, in the order they are drawn.
///
/// The order is the order they were asked for, and it is also the order
/// they are read: the rules for the site, then the contract for the
/// service, then what happens to the reader.
const signinLinkSlugs = <String>['terms', 'terms-of-service', 'privacy'];

/// The label for a slug, matching what the console calls that page.
///
/// A `switch` rather than a map so a slug nobody has a name for is a
/// compile-time hole rather than a null at the bottom of a screen.
String signinLinkLabel(String slug) => switch (slug) {
  'terms' => 'Terms of Use',
  'terms-of-service' => 'Terms of Service',
  'privacy' => 'Privacy Policy',
  _ => slug,
};

/// Which of the three links this surface draws.
///
/// Empty in a browser, whatever the switches say: the website's footer
/// already carries all three on every page, and a second row of them
/// under the form would be the same three links twice.
///
/// [published] is the set of site-page slugs that are published.
/// A page outside it is not named at all — unlike the consent sentence
/// under the register button, which says the words and merely does not
/// link them. The difference is that the sentence has to name what is
/// being agreed to; a row of links has nothing to say about a document
/// nobody can read.
List<SigninLink> signinFooterLinks({
  required Surface surface,
  required Set<String> published,
  required bool termsIos,
  required bool termsAndroid,
  required bool termsOfServiceIos,
  required bool termsOfServiceAndroid,
  required bool privacyIos,
  required bool privacyAndroid,
}) {
  bool offered(String slug) => switch (surface) {
    Surface.ios => switch (slug) {
      'terms' => termsIos,
      'terms-of-service' => termsOfServiceIos,
      'privacy' => privacyIos,
      _ => false,
    },
    Surface.android => switch (slug) {
      'terms' => termsAndroid,
      'terms-of-service' => termsOfServiceAndroid,
      'privacy' => privacyAndroid,
      _ => false,
    },
    // Not a fallback to the web's answer, the way `passkeyOffered`
    // treats desktop: there is no web switch here to fall back to,
    // because the website answers this question with its footer.
    Surface.web || Surface.desktop => false,
  };

  return [
    for (final slug in signinLinkSlugs)
      if (offered(slug) && published.contains(slug))
        (slug: slug, label: signinLinkLabel(slug)),
  ];
}

/// Whether the sign-in screen offers the way to the demo page here.
///
/// The surface switch is ANDed onto [showDemoAccounts]'s four
/// conditions rather than replacing any of them, and that is the whole
/// point of this function existing instead of an `&&` in a widget tree.
/// `demo_accounts.dart` opens by saying that the demo password is
/// compiled into the bundle and readable by anyone who opens the app;
/// the gates in front of it only ever get added to.
///
/// So: the build has to carry the password, the console has to offer
/// the demo at all, this platform's own switch has to be on, and the
/// two conditions about where the visitor is standing still hold.
///
/// There is no `onWeb`, deliberately. The browser keeps the panel it has
/// always had under the form — twelve rows of demo logins are a fine
/// thing to scroll past on a wide window and a long way to scroll on a
/// phone, which is why the apps get a page instead.
bool demoPageOffered({
  required Surface surface,
  required bool buildAllows,
  required bool platformOffers,
  required bool onIos,
  required bool onAndroid,
  required bool isSignUp,
  required bool atCompanyDoor,
}) {
  final here = switch (surface) {
    Surface.ios => onIos,
    Surface.android => onAndroid,
    Surface.web || Surface.desktop => false,
  };
  return here &&
      showDemoAccounts(
        buildAllows: buildAllows,
        platformOffers: platformOffers,
        isSignUp: isSignUp,
        atCompanyDoor: atCompanyDoor,
      );
}

/// Whether the sign-in screen draws the demo panel under the form.
///
/// What the screen did before any of this, and it keeps doing it — in a
/// browser. In an app the same four gates now lead to [demoPageOffered]
/// and a link instead, so the twelve rows are not between the form and
/// the bottom of a phone screen.
bool demoPanelOffered({
  required Surface surface,
  required bool buildAllows,
  required bool platformOffers,
  required bool isSignUp,
  required bool atCompanyDoor,
}) =>
    !surface.isApp &&
    showDemoAccounts(
      buildAllows: buildAllows,
      platformOffers: platformOffers,
      isSignUp: isSignUp,
      atCompanyDoor: atCompanyDoor,
    );
