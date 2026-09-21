/// Which of the four surfaces this build is, for the settings that
/// differ between them.
///
/// Most of the product does not need to know. The handful of places
/// that do are the ones where the same decision has a different right
/// answer in a browser and in an app store build — whether there is a
/// front page in front of the sign-in form, whether a passkey button
/// can work, whether a stranger may open an account — and every one of
/// them was getting the answer from a slightly different expression
/// before this existed.
///
/// One expression, in one place, because the subtle half is easy to
/// get wrong twice: see [currentSurface].
library;

import 'package:flutter/foundation.dart';

/// Where this build is running.
enum Surface {
  /// A browser, on anything. Includes a phone browser.
  web,

  /// The Android app from an app store or a sideload.
  android,

  /// The iOS app.
  ios,

  /// Linux, macOS or Windows, compiled rather than served. There is no
  /// desktop build today; it is named rather than folded into [web] so
  /// that a rule about app stores does not silently become a rule
  /// about "not a browser".
  desktop;

  /// Whether this is one of the two app-store builds.
  ///
  /// The question nearly every caller is actually asking.
  bool get isApp => this == Surface.android || this == Surface.ios;
}

/// Which surface this build is.
///
/// The `kIsWeb` test comes FIRST and it is load-bearing, not
/// belt-and-braces. Flutter web running in Safari on an iPhone answers
/// [TargetPlatform.iOS] to [defaultTargetPlatform] — that getter is
/// about which look and feel to adopt, not about how the code was
/// compiled — so a check on the platform alone calls a phone browser an
/// app. Every rule in this file would then apply to most of the
/// product's visitors.
Surface get currentSurface {
  if (kIsWeb) return Surface.web;
  return switch (defaultTargetPlatform) {
    TargetPlatform.android => Surface.android,
    TargetPlatform.iOS => Surface.ios,
    _ => Surface.desktop,
  };
}

/// Whether the passkey button is switched on for this surface.
///
/// `0638`. Three switches and not one, because the three surfaces need
/// three different things done to them before the button can work:
/// all of them need passkeys turned on for the project in the Supabase
/// dashboard, Android additionally needs an `assetlinks.json` served
/// from the domain, and iOS additionally needs an Associated Domains
/// entitlement and an `apple-app-site-association`. Those are finished
/// on different days by different people, and a single switch would
/// mean the first surface to be ready turning the button on for the two
/// that are not.
///
/// Desktop gets the web's answer. There is no desktop build, and if
/// there were, the console has said nothing about it — falling back to
/// the switch an operator has actually seen beats inventing a fourth.
/// It does not matter much either way: nothing on a desktop build can
/// reach an authenticator, so the capability check refuses first.
bool passkeyOffered(
  Surface surface, {
  required bool onWeb,
  required bool onAndroid,
  required bool onIos,
}) => switch (surface) {
  Surface.android => onAndroid,
  Surface.ios => onIos,
  Surface.web || Surface.desktop => onWeb,
};

/// Whether the way on to the registration form is switched on here.
///
/// `0638`. [inTheApps] is a VETO over [console] rather than a
/// replacement for it: the app draws the link when both are on. That is
/// what lets a platform take strangers on the website and not in the
/// app — an app store can have rules about what an account costs and
/// who may open one — and it is not something one switch could say.
///
/// Neither of these is a security control. `signup_enabled` is, and
/// `0563` enforces it with a trigger on `auth.users`; somebody who
/// reaches the form another way is still refused there. These decide
/// only what is drawn.
bool registrationOffered(
  Surface surface, {
  required bool console,
  required bool inTheApps,
}) => console && (!surface.isApp || inTheApps);
