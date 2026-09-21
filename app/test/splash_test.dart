/// The five seconds before the first real screen.
///
/// Asked for as "splash screen stays for 5 seconds before it goes to
/// the next screen", with a picture settable in the console and the
/// logo on white — or black in dark mode — where nobody has set one.
///
/// Three things here could be wrong in ways nothing else would notice:
///
///   * THE CLOCK. The hold is what is LEFT of five seconds from process
///     start, not five seconds from the first frame. Measured from the
///     frame, a cold start over a bad connection would show the system
///     splash, then `Supabase.initialize` for up to fifteen seconds,
///     then five more — longest exactly where patience is shortest.
///   * WHICH PICTURE. The fallback is the logo, and in dark mode the
///     DARK logo, because the ordinary one is usually drawn for white
///     and vanishes on black.
///   * WHERE. Apps only. A browser tab that sits on a logo for five
///     seconds is a tab somebody closes, and the same build serves the
///     marketing site.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iakauntan/src/core/splash.dart';
import 'package:iakauntan/src/core/surface.dart';
import 'package:iakauntan/src/features/landing/splash_screen.dart';

void main() {
  group('how long is left', () {
    final start = DateTime(2026, 9, 19, 8);

    test('all of it at the moment the process started', () {
      expect(splashRemaining(start, started: start), splashHold);
    });

    test('and less of it once starting up has taken a while', () {
      expect(
        splashRemaining(start.add(const Duration(seconds: 2)), started: start),
        const Duration(seconds: 3),
      );
    });

    test('none of it where the start used the whole hold', () {
      // The case the request did not mention and the phone will meet
      // every cold morning: `Supabase.initialize` waits up to fifteen
      // seconds. Adding five to that would be the slowest start made
      // slower still.
      expect(
        splashRemaining(start.add(const Duration(seconds: 9)), started: start),
        Duration.zero,
      );
    });

    test('and never a negative hold, which is a timer that never fires', () {
      expect(
        splashRemaining(
          start.add(const Duration(minutes: 5)),
          started: start,
        ).isNegative,
        isFalse,
      );
    });

    test('five seconds, from the one constant that says so', () {
      // Named rather than typed twice: the console's card reads this
      // to tell an operator how long the screen they are configuring
      // is on show.
      expect(splashHold, const Duration(seconds: 5));
    });
  });

  group('which surfaces hold one', () {
    test('the two apps', () {
      expect(splashHeld(Surface.ios), isTrue);
      expect(splashHeld(Surface.android), isTrue);
    });

    test('and not a browser', () {
      expect(splashHeld(Surface.web), isFalse);
      expect(splashHeld(Surface.desktop), isFalse);
    });
  });

  group('which picture', () {
    test('the uploaded one wins, in both brightnesses', () {
      for (final dark in [false, true]) {
        expect(
          splashImage(
            uploaded: 'https://x.test/splash.png',
            logo: 'https://x.test/logo.png',
            logoDark: 'https://x.test/logo-dark.png',
            dark: dark,
          ),
          'https://x.test/splash.png',
          reason: 'dark=$dark',
        );
      }
    });

    test('the logo where nobody uploaded one', () {
      expect(
        splashImage(
          uploaded: null,
          logo: 'https://x.test/logo.png',
          logoDark: 'https://x.test/logo-dark.png',
          dark: false,
        ),
        'https://x.test/logo.png',
      );
    });

    test('and the DARK logo on black', () {
      // The half worth asserting. A mark drawn for a white page
      // disappears on black, which is the background dark mode gets.
      expect(
        splashImage(
          uploaded: null,
          logo: 'https://x.test/logo.png',
          logoDark: 'https://x.test/logo-dark.png',
          dark: true,
        ),
        'https://x.test/logo-dark.png',
      );
    });

    test('falling back to the ordinary logo where there is no dark one', () {
      // Most deployments upload one logo, so this is the common case
      // rather than an edge one.
      expect(
        splashImage(
          uploaded: null,
          logo: 'https://x.test/logo.png',
          logoDark: null,
          dark: true,
        ),
        'https://x.test/logo.png',
      );
    });

    test('and an empty string is nothing, not a URL', () {
      // `platform_save_landing_page` blanks the column rather than
      // storing '', but a payload can arrive from anywhere and
      // `Image.network('')` is a broken image on the first screen.
      expect(
        splashImage(uploaded: '  ', logo: '', logoDark: null, dark: false),
        isNull,
      );
    });
  });

  group('and the two colours', () {
    test('white on light, black on dark', () {
      expect(splashBackground(dark: false), const Color(0xFFFFFFFF));
      expect(splashBackground(dark: true), const Color(0xFF000000));
    });

    test('with ink that can be read on each', () {
      expect(splashInk(dark: false), const Color(0xFF000000));
      expect(splashInk(dark: true), const Color(0xFFFFFFFF));
    });
  });

  group('what is drawn', () {
    testWidgets('the wordmark where there is no picture at all', (t) async {
      await t.pumpWidget(
        const SplashView(image: null, wordmark: 'Sinar Books', dark: false),
      );
      expect(find.text('Sinar Books'), findsOneWidget);
    });

    testWidgets('and the background is the one the rules chose', (t) async {
      await t.pumpWidget(
        const SplashView(image: null, wordmark: 'Sinar Books', dark: true),
      );
      final container = t.widget<Container>(find.byKey(const ValueKey('splash')));
      expect(container.color, splashBackground(dark: true));
    });

    testWidgets('a browser is given its child and no splash', (t) async {
      // The control on the whole feature. Without this, "the website is
      // untouched" is a comment.
      await t.pumpWidget(
        const MaterialApp(
          home: SplashGate(
            surface: Surface.web,
            child: Text('the app', textDirection: TextDirection.ltr),
          ),
        ),
      );
      expect(find.text('the app'), findsOneWidget);
      expect(find.byKey(const ValueKey('splash')), findsNothing);
    });
  });
}
