import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/features/landing/landing_content.dart';
import 'package:iakauntan/src/features/landing/landing_screen.dart';

/// Which ways in the page draws, where, and at what width.
///
/// Three reports from a phone are pinned here.
///
/// The hero drew a filled button and an outlined one unconditionally,
/// and the filled one fell back to the sign-in label when
/// `register_enabled` was off. So a platform with registration closed
/// got two buttons reading "Sign in", side by side, going to the same
/// place. A pair of identical buttons is not a smaller call to action;
/// it is a page that looks broken.
///
/// The masthead had the mirror of it. The sign-in link was drawn only
/// on wide screens, on the reasoning that a phone has the register
/// button instead — which is true right up until registration is
/// closed, and then a phone gets a bar with a burger, a logo and
/// nothing to press at all.
///
/// And then: "split into mobile and desktop, also split sign in and
/// create an account". `0321` makes that eight switches, and what is
/// asserted below is that each one moves exactly the button it names at
/// exactly the width it names.
///
/// Asserted on what a visitor can see and reach, not on which widget
/// draws it, so the layout stays free to change.
void main() {
  /// [wide] is the side of `Land.wide` — 760 — the page is drawn at.
  /// A phone and a desktop are two different pages here, so every
  /// assertion has to say which one it is about.
  Future<void> pump(
    WidgetTester tester,
    LandingContent content, {
    bool wide = false,
  }) async {
    tester.view.physicalSize = Size(wide ? 1280 : 420, 3600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          // Reduce-motion, so the reveal animations do not leave their
          // stagger timers pending past the end of the test. What is
          // asserted here is which labels the page draws, which is the
          // same either way — and it is the path somebody who has asked
          // their system for less movement actually gets.
          body: Builder(
            builder: (context) => MediaQuery(
              data: MediaQuery.of(context).copyWith(disableAnimations: true),
              child: LandingPage(content: content, preview: true),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  /// Every place on the page reading exactly [label].
  ///
  /// By text rather than by button type: `ButtonStyleButton` is
  /// abstract and `widgetWithText` matches on runtime type, so it finds
  /// none of the concrete buttons. What matters here is what a visitor
  /// can read and reach, which is the text.
  int labelled(WidgetTester tester, String label) =>
      find.text(label).evaluate().length;

  /// Every way-in button on the page, named by where it sits.
  ///
  /// `bar:Sign in`, `hero:Create an account`, and so on. By position
  /// rather than by widget, because the point of these switches is what
  /// a visitor sees at a given width — the bar is the strip across the
  /// top, the hero is the band around the headline, and anything below
  /// that is the footer.
  ///
  /// The footer is deliberately NOT in this set. `0578` made it
  /// switchable too, and it is asserted separately below on the labels
  /// it draws: folding it in here would make every existing assertion
  /// about the bar and the hero depend on a footer setting as well.
  Set<String> drawn(WidgetTester tester) {
    final headline = tester.getRect(find.textContaining('Accounting').first);
    final out = <String>{};
    for (final label in ['Sign in', 'Create an account']) {
      for (final e in find.text(label).evaluate()) {
        final dy = tester.getTopLeft(find.byWidget(e.widget)).dy;
        if (dy < headline.top) {
          out.add('bar:$label');
        } else if (dy < headline.bottom + 1000) {
          out.add('hero:$label');
        }
      }
    }
    return out;
  }

  testWidgets('registration closed: one way in, and it is not doubled', (
    tester,
  ) async {
    for (final wide in [true, false]) {
      await pump(
        tester,
        const LandingContent(published: true, registerEnabled: false),
        wide: wide,
      );

      // Nothing anywhere invites somebody to register when they cannot.
      expect(labelled(tester, 'Create an account'), 0, reason: 'wide: $wide');

      // And there is at least one way in on the page.
      expect(labelled(tester, 'Sign in'), greaterThan(0));
    }
  });

  testWidgets('registration open: both ways in are offered', (tester) async {
    for (final wide in [true, false]) {
      await pump(
        tester,
        const LandingContent(published: true, registerEnabled: true),
        wide: wide,
      );
      expect(labelled(tester, 'Sign in'), greaterThan(0));
      expect(labelled(tester, 'Create an account'), greaterThan(0));
    }
  });

  testWidgets('the bar and the hero each offer both, by default', (
    tester,
  ) async {
    // The shipped page, at both widths. Everything below turns one of
    // these off; this is what it is turned off from.
    for (final wide in [true, false]) {
      await pump(tester, const LandingContent(published: true), wide: wide);
      expect(drawn(tester), {
        'bar:Sign in',
        'bar:Create an account',
        'hero:Sign in',
        'hero:Create an account',
      }, reason: 'wide: $wide');
    }
  });

  testWidgets('each switch moves its own button, at its own width', (
    tester,
  ) async {
    // The whole point of there being eight. A switch that also moved
    // the phone's button, or the hero's, would look right in the
    // console and wrong on the page — and the operator would have no
    // way to tell which of the two was lying.
    const cases = <String, String>{
      'bar_sign_in_desktop': 'bar:Sign in',
      'bar_register_desktop': 'bar:Create an account',
      'hero_sign_in_desktop': 'hero:Sign in',
      'hero_register_desktop': 'hero:Create an account',
      'bar_sign_in_mobile': 'bar:Sign in',
      'bar_register_mobile': 'bar:Create an account',
      'hero_sign_in_mobile': 'hero:Sign in',
      'hero_register_mobile': 'hero:Create an account',
    };
    const all = {
      'bar:Sign in',
      'bar:Create an account',
      'hero:Sign in',
      'hero:Create an account',
    };

    for (final entry in cases.entries) {
      final desktopSwitch = entry.key.endsWith('_desktop');
      for (final wide in [true, false]) {
        await pump(
          tester,
          parseLandingContent({
            'page': {'is_published': true, entry.key: false},
          }),
          wide: wide,
        );
        // A desktop switch does nothing on a phone, and the other way
        // round. That is the half of this nobody would notice missing.
        final gone = desktopSwitch == wide ? {entry.value} : <String>{};
        expect(
          drawn(tester),
          all.difference(gone),
          reason: '${entry.key} off, wide: $wide',
        );
      }
    }
  });

  testWidgets('the hero never draws the same label twice', (tester) async {
    // The exact shape of the defect that started this: within one Wrap
    // — the hero's row of calls to action — no two buttons may read the
    // same.
    for (final registerEnabled in [true, false]) {
      for (final wide in [true, false]) {
        await pump(
          tester,
          LandingContent(published: true, registerEnabled: registerEnabled),
          wide: wide,
        );

        final wraps = find.byType(Wrap).evaluate().toList();
        for (var i = 0; i < wraps.length; i++) {
          final labels = tester
              .widgetList<Text>(
                find.descendant(
                  of: find.byWidget(wraps[i].widget),
                  matching: find.byType(Text),
                ),
              )
              .map((t) => t.data)
              .whereType<String>()
              .where((t) => t == 'Sign in' || t == 'Create an account')
              .toList();
          expect(
            labels.length,
            labels.toSet().length,
            reason: 'a row offers the same way in twice: $labels',
          );
        }
      }
    }
  });

  testWidgets('one button left is the filled one, not a lone outline', (
    tester,
  ) async {
    // Whichever survives alone becomes the primary. An outlined button
    // by itself under a headline reads as the secondary half of a pair
    // whose other half failed to load.
    await pump(
      tester,
      parseLandingContent({
        'page': {
          'is_published': true,
          'hero_register_mobile': false,
          'bar_register_mobile': false,
        },
      }),
    );
    expect(drawn(tester), {'bar:Sign in', 'hero:Sign in'});
    expect(find.widgetWithText(FilledButton, 'Sign in'), findsWidgets);
    expect(find.widgetWithText(OutlinedButton, 'Sign in'), findsNothing);
  });

  testWidgets('all eight off still leaves a way in at the bottom', (
    tester,
  ) async {
    // The DEFAULT, not an invariant any more. `0321` made this a rule
    // — somebody who has read to the bottom should not have to guess
    // the address, and a footer link is not a button competing for
    // attention at the top — and `0578` kept the behaviour and made it
    // reachable: the four footer switches ship on, so a platform that
    // sets none of them sees exactly what this asserts. What happens
    // when they ARE set is the four tests below.
    await pump(
      tester,
      parseLandingContent({
        'page': {
          'is_published': true,
          'bar_sign_in_desktop': false,
          'bar_sign_in_mobile': false,
          'bar_register_desktop': false,
          'bar_register_mobile': false,
          'hero_sign_in_desktop': false,
          'hero_sign_in_mobile': false,
          'hero_register_desktop': false,
          'hero_register_mobile': false,
        },
      }),
    );
    expect(drawn(tester), isEmpty);
    expect(labelled(tester, 'Sign in'), greaterThan(0));
  });

  /// Every way-in label in the footer, by name.
  ///
  /// Anything below the hero band. `drawn` stops there on purpose, so
  /// this is the other half of the same question: what a visitor who
  /// has read to the bottom is offered.
  Set<String> inFooter(WidgetTester tester) {
    final headline = tester.getRect(find.textContaining('Accounting').first);
    final out = <String>{};
    for (final label in ['Sign in', 'Create an account']) {
      for (final e in find.text(label).evaluate()) {
        if (tester.getTopLeft(find.byWidget(e.widget)).dy >
            headline.bottom + 1000) {
          out.add(label);
        }
      }
    }
    return out;
  }

  testWidgets('each footer switch moves its own link, at its own width', (
    tester,
  ) async {
    // `0578`. The same grain as the eight above: a footer link is the
    // same three decisions — where it sits, how wide the screen is, and
    // which way in it offers.
    for (final (key, wide, gone) in [
      ('footer_sign_in_desktop', true, 'Sign in'),
      ('footer_sign_in_mobile', false, 'Sign in'),
      ('footer_register_desktop', true, 'Create an account'),
      ('footer_register_mobile', false, 'Create an account'),
    ]) {
      await pump(
        tester,
        parseLandingContent({
          'page': {'is_published': true, key: false},
        }),
        wide: wide,
      );
      expect(
        inFooter(tester),
        isNot(contains(gone)),
        reason: '$key off still shows "$gone" in the footer',
      );

      // And the other width is untouched, which is the half a switch
      // named "desktop" could silently get wrong.
      await pump(
        tester,
        parseLandingContent({
          'page': {'is_published': true, key: false},
        }),
        wide: !wide,
      );
      expect(
        inFooter(tester),
        contains(gone),
        reason: '$key off also took "$gone" away at the other width',
      );
    }
  });

  testWidgets('a footer switch leaves the bar and the hero alone', (
    tester,
  ) async {
    // The mirror of the test above. Turning the footer off must not
    // quietly take the buttons at the top with it.
    await pump(
      tester,
      parseLandingContent({
        'page': {
          'is_published': true,
          'footer_sign_in_desktop': false,
          'footer_register_desktop': false,
        },
      }),
      wide: true,
    );
    expect(inFooter(tester), isEmpty);
    expect(drawn(tester), {
      'bar:Sign in',
      'bar:Create an account',
      'hero:Sign in',
      'hero:Create an account',
    });
  });

  testWidgets('both footer links off draws no "Get started" heading', (
    tester,
  ) async {
    // A heading with nothing under it reads as a broken page rather
    // than a deliberate one — the same rule the legal column in that
    // widget already follows.
    await pump(
      tester,
      parseLandingContent({
        'page': {
          'is_published': true,
          'footer_sign_in_desktop': false,
          'footer_register_desktop': false,
        },
      }),
      wide: true,
    );
    expect(find.text('Get started'), findsNothing);
  });

  testWidgets('one footer link left still keeps the heading', (tester) async {
    // The control for the test above: the heading goes when the column
    // is empty, not whenever a switch is touched.
    await pump(
      tester,
      parseLandingContent({
        'page': {'is_published': true, 'footer_register_desktop': false},
      }),
      wide: true,
    );
    expect(find.text('Get started'), findsOneWidget);
    expect(inFooter(tester), {'Sign in'});
  });

  testWidgets('registration closed takes the footer link with it', (
    tester,
  ) async {
    // `register_enabled` says whether there is a link to draw at all;
    // the footer switches say where it is drawn. Off, and the footer
    // must not offer a way to register that the platform will refuse.
    await pump(
      tester,
      parseLandingContent({
        'page': {'is_published': true, 'register_enabled': false},
      }),
      wide: true,
    );
    expect(inFooter(tester), {'Sign in'});
  });

  testWidgets('the menu on a phone follows the bar it folds up', (
    tester,
  ) async {
    // Hiding a button on the bar and leaving it one tap away behind the
    // menu would be hiding it from nobody.
    await pump(
      tester,
      parseLandingContent({
        'page': {
          'is_published': true,
          'bar_sign_in_mobile': false,
          'bar_register_mobile': false,
        },
      }),
    );

    await tester.tap(find.byTooltip('Menu'));
    await tester.pumpAndSettle();
    for (final label in ['Sign in', 'Create an account']) {
      expect(
        find.descendant(
          of: find.byType(BottomSheet),
          matching: find.text(label),
        ),
        findsNothing,
        reason: 'the menu still offers "$label"',
      );
    }
  });

  testWidgets('and keeps whichever of the two the bar keeps', (tester) async {
    await pump(
      tester,
      parseLandingContent({
        'page': {'is_published': true, 'bar_register_mobile': false},
      }),
    );

    await tester.tap(find.byTooltip('Menu'));
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byType(BottomSheet),
        matching: find.text('Sign in'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byType(BottomSheet),
        matching: find.text('Create an account'),
      ),
      findsNothing,
    );
  });
}
