import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/features/landing/landing_content.dart';
import 'package:iakauntan/src/features/landing/landing_screen.dart';

/// How many ways in the page draws, and that none of them is a
/// duplicate.
///
/// Two bugs this pins, both found on a phone rather than here.
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
/// Asserted on what a visitor can see and reach, not on which widget
/// draws it, so the layout stays free to change.
void main() {
  Future<void> pump(WidgetTester tester, LandingContent content) async {
    tester.view.physicalSize = const Size(420, 3200);
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

  testWidgets('registration closed: one way in, and it is not doubled', (
    tester,
  ) async {
    await pump(
      tester,
      const LandingContent(published: true, registerEnabled: false),
    );

    // Nothing anywhere invites somebody to register when they cannot.
    expect(labelled(tester, 'Create an account'), 0);

    // And there is at least one way in on the page.
    expect(labelled(tester, 'Sign in'), greaterThan(0));
  });

  testWidgets('registration open: both ways in are offered', (tester) async {
    await pump(
      tester,
      const LandingContent(published: true, registerEnabled: true),
    );
    expect(labelled(tester, 'Sign in'), greaterThan(0));
    expect(labelled(tester, 'Create an account'), greaterThan(0));
  });

  testWidgets('the bar on a phone always has something to press', (
    tester,
  ) async {
    // The masthead half of the same report. The sign-in link was drawn
    // only on wide screens, on the reasoning that a phone has the
    // register button instead — true right up until registration is
    // closed, and then the bar is a burger, a logo and nothing else.
    //
    // Asserted by position rather than by widget: whatever draws it,
    // something a visitor can press to get in has to sit in the bar
    // across the top, not four screens down the page.
    for (final registerEnabled in [true, false]) {
      await pump(
        tester,
        LandingContent(published: true, registerEnabled: registerEnabled),
      );

      final inTheBar = <String>[];
      for (final label in ['Sign in', 'Create an account']) {
        for (final e in find.text(label).evaluate()) {
          if (tester.getTopLeft(find.byWidget(e.widget)).dy < 96) {
            inTheBar.add(label);
          }
        }
      }
      expect(
        inTheBar,
        isNotEmpty,
        reason: 'registerEnabled: $registerEnabled — no way in on the bar',
      );
    }
  });

  testWidgets('the hero never draws the same label twice', (tester) async {
    // The exact shape of the defect: within one Wrap — the hero's row
    // of calls to action — no two buttons may read the same.
    for (final registerEnabled in [true, false]) {
      await pump(
        tester,
        LandingContent(published: true, registerEnabled: registerEnabled),
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
  });
}
