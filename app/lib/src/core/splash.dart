/// The screen an app holds for a moment before the first real one.
///
/// Asked for as: the splash screen stays for five seconds before it
/// goes to the next screen, with the picture settable in the console
/// and the logo on white — or on black in dark mode — where nobody has
/// set one.
///
/// ## Five seconds, measured from when the process started
///
/// Not from when this widget was first built, and the difference is the
/// whole of it. Before any Dart runs, Android has already been drawing
/// `launch_background` and iOS its launch storyboard, and
/// `Supabase.initialize` in `main.dart` waits up to fifteen seconds
/// after that. Held from first build, a cold start would show a
/// system splash, then this one for five seconds on top — six or seven
/// seconds of nothing on a slow network, and longest exactly where
/// patience is shortest.
///
/// [markSplashStart] is called at the top of `main`, before anything
/// slow, and [splashRemaining] is what is left of the five seconds
/// after that. On a warm start it is usually most of them; on a cold
/// one over a bad connection it can be none, and none is the right
/// answer.
///
/// ## And only in the apps
///
/// A browser tab that sits on a logo for five seconds before showing
/// the page is a tab somebody closes, and the same code runs the
/// marketing site. `splashHeld` answers false for [Surface.web], so the
/// website is exactly what it was.
///
/// ## What is drawn where nobody uploaded anything
///
/// The logo, on white in light mode and on black in dark — which is
/// what was asked for, and is also the only fallback that cannot be
/// wrong. Every deployment has a logo; `landing_page.logo_url` has a
/// default and `LandingContent` falls back again to the one the product
/// ships with. A splash with no picture at all would be five seconds of
/// flat colour, which reads as a hang rather than as a brand.
library;

import 'package:flutter/material.dart';

import 'surface.dart';

/// How long the splash is held, once.
///
/// One constant, named, because the number was asked for as a number.
/// Anything that wants to know how long the splash lasts asks this
/// rather than writing `5` again.
const splashHold = Duration(seconds: 5);

/// When this process started, near enough.
///
/// A variable stamped by [markSplashStart] rather than a `final`,
/// because a top-level `final` in Dart is initialised LAZILY — the
/// first read of it would be `SplashGate.initState`, on the first
/// frame, which is after `Supabase.initialize` has had its fifteen
/// seconds. It would have recorded the moment the wait ended as the
/// moment it began, and the splash would then have run its full five
/// seconds on top of the slowest starts.
DateTime splashStarted = DateTime.now();

/// Stamps [splashStarted]. Called at the top of `main`.
void markSplashStart() => splashStarted = DateTime.now();

/// What is left of [splashHold] at [now].
///
/// Never negative: a start slow enough to have used the whole hold
/// gets [Duration.zero], and the caller draws the app immediately.
Duration splashRemaining(DateTime now, {DateTime? started}) {
  final gone = now.difference(started ?? splashStarted);
  final left = splashHold - gone;
  return left.isNegative ? Duration.zero : left;
}

/// Whether this surface holds a splash at all.
///
/// The apps, and nothing else. See the library comment.
bool splashHeld(Surface surface) => surface.isApp;

/// The picture the splash draws, or null to draw the wordmark instead.
///
/// [uploaded] is `landing_page.splash_image_url` — what an operator put
/// on the Mobile Application page, and the answer whenever there is
/// one. The fallback is the logo, and which logo depends on which
/// background it is about to sit on: the dark logo exists precisely
/// because the ordinary one disappears on black.
///
/// [logoDark] falling back to [logo] rather than to nothing is the
/// ordinary case, not an edge one — most deployments upload one logo.
String? splashImage({
  required String? uploaded,
  required String? logo,
  required String? logoDark,
  required bool dark,
}) {
  final chosen = uploaded?.trim();
  if (chosen != null && chosen.isNotEmpty) return chosen;
  final fallback = dark ? (logoDark ?? logo) : logo;
  final trimmed = fallback?.trim();
  return (trimmed == null || trimmed.isEmpty) ? null : trimmed;
}

/// The background the splash sits on.
///
/// White in light mode and black in dark, as asked for, and not the
/// brand colour. A logo is drawn to sit on one of those two — that is
/// what `branding_admin.dart` previews it against — and a mark composed
/// for white on a deployment's own purple is the one outcome worth
/// ruling out.
Color splashBackground({required bool dark}) =>
    dark ? const Color(0xFF000000) : const Color(0xFFFFFFFF);

/// What is drawn over that background where there is no picture at all.
///
/// Black on white and white on black, for the same reason the
/// background is not the brand colour: this has to be legible on a
/// deployment nobody has finished setting up.
Color splashInk({required bool dark}) =>
    dark ? const Color(0xFFFFFFFF) : const Color(0xFF000000);
