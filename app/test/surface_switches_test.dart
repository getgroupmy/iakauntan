import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/core/surface.dart';

/// The same decision with a different right answer on each surface.
///
/// Three switches where there was one, and the reason is not
/// symmetry: the three surfaces need three different things done to
/// them before a passkey button can work — a dashboard setting for all
/// of them, an `assetlinks.json` for Android, an entitlement and an
/// `apple-app-site-association` for iOS — and they are finished on
/// different days by different people.
///
/// What is asserted here is that turning one on turns exactly one on.
/// A switch that reached two surfaces would draw a button on the one
/// whose setup is not done, which is the failure the three switches
/// exist to prevent and is invisible from the console.
void main() {
  group('which surface this is', () {
    test('a phone build is one of the two apps', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      expect(currentSurface, Surface.android);
      expect(currentSurface.isApp, isTrue);
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      expect(currentSurface, Surface.ios);
      expect(currentSurface.isApp, isTrue);
      debugDefaultTargetPlatformOverride = null;
    });

    test('and a desktop build is not', () {
      for (final p in [
        TargetPlatform.linux,
        TargetPlatform.macOS,
        TargetPlatform.windows,
      ]) {
        debugDefaultTargetPlatformOverride = p;
        expect(currentSurface, Surface.desktop, reason: '$p');
        expect(currentSurface.isApp, isFalse, reason: '$p');
        debugDefaultTargetPlatformOverride = null;
      }
    });

    // NOT ASSERTED, and said out loud rather than left as a hole that
    // looks like coverage: that a phone BROWSER is `Surface.web`.
    //
    // It is the case this getter exists for. Flutter web in Safari on
    // an iPhone answers `TargetPlatform.iOS` to
    // `defaultTargetPlatform`, so without the `kIsWeb` test first, most
    // of the product's visitors would be told they are in an app — no
    // front page, and the wrong passkey switch.
    //
    // `flutter test` runs on the VM, where `kIsWeb` is a const false
    // and the compiler folds the branch away. Nothing here can observe
    // its removal. `flutter test --platform chrome` could; this
    // repository does not run it.
  });

  group('the passkey button', () {
    test('is drawn on the surface whose switch is on, and only there', () {
      // One at a time, which is how the setup actually finishes.
      expect(
        passkeyOffered(Surface.android,
            onWeb: false, onAndroid: true, onIos: false),
        isTrue,
      );
      expect(
        passkeyOffered(Surface.ios,
            onWeb: false, onAndroid: true, onIos: false),
        isFalse,
      );
      expect(
        passkeyOffered(Surface.web,
            onWeb: false, onAndroid: true, onIos: false),
        isFalse,
      );
    });

    test('and the web switch is only the web\'s', () {
      // The failure that would be invisible: an operator turns the
      // button on for the website, having done the dashboard step, and
      // it appears in two apps whose association files do not exist
      // yet. Every press there does nothing at all.
      expect(
        passkeyOffered(Surface.ios,
            onWeb: true, onAndroid: false, onIos: false),
        isFalse,
      );
      expect(
        passkeyOffered(Surface.android,
            onWeb: true, onAndroid: false, onIos: false),
        isFalse,
      );
    });

    test('and iOS and Android do not answer for each other', () {
      // "Separately" is the request, and this is what it means: the
      // Apple half and the Android half are done by different people
      // and neither waits for the other.
      expect(
        passkeyOffered(Surface.ios,
            onWeb: false, onAndroid: false, onIos: true),
        isTrue,
      );
      expect(
        passkeyOffered(Surface.android,
            onWeb: false, onAndroid: false, onIos: true),
        isFalse,
      );
    });

    test('a desktop build takes the answer an operator has actually given', () {
      // There is no desktop build, and the console has no fourth
      // switch. Falling back to the one somebody has seen beats
      // inventing an answer — and nothing on a desktop build can reach
      // an authenticator anyway, so the capability check refuses
      // first.
      expect(
        passkeyOffered(Surface.desktop,
            onWeb: true, onAndroid: false, onIos: false),
        isTrue,
      );
      expect(
        passkeyOffered(Surface.desktop,
            onWeb: false, onAndroid: true, onIos: true),
        isFalse,
      );
    });
  });

  group('the way on to registration', () {
    test('needs both switches in the apps', () {
      // A veto, not a replacement. The app draws the link when the
      // platform's switch is on AND the app's is.
      expect(registrationOffered(Surface.ios, console: true, inTheApps: true),
          isTrue);
      expect(registrationOffered(Surface.ios, console: true, inTheApps: false),
          isFalse);
      expect(
          registrationOffered(Surface.android,
              console: true, inTheApps: false),
          isFalse);
    });

    test('and closing the apps leaves the website open', () {
      // The whole point of a second switch. An app store can have
      // rules about what an account costs and who may open one; the
      // website does not stop taking people because of them.
      expect(registrationOffered(Surface.web, console: true, inTheApps: false),
          isTrue);
      expect(
          registrationOffered(Surface.desktop,
              console: true, inTheApps: false),
          isTrue);
    });

    test('but the app switch cannot open a door the platform has closed', () {
      // It only takes away. An operator who has turned "Offer an
      // account" off means it everywhere, and a second switch that
      // could override the first would be a way to reopen the door by
      // accident.
      expect(registrationOffered(Surface.ios, console: false, inTheApps: true),
          isFalse);
      expect(registrationOffered(Surface.web, console: false, inTheApps: true),
          isFalse);
    });
  });
}
