import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/features/landing/landing_content.dart';
import 'package:iakauntan/src/features/landing/landing_screen.dart';

/// The mark on the masthead, and how much of it survives a phone.
///
/// Reported from a real Android handset: at 412 the name read "iAka…"
/// with, as it was put, plenty of empty space beside it. Both halves of
/// that were true and they had the same cause.
///
/// The masthead row was
///
///     Flexible(child: LandingMark(...)),
///     const Spacer(),
///     ... Flexible(child: FilledButton(...)),
///
/// Three flex children with a factor of one each. A `Spacer` is an
/// `Expanded`, so it took a THIRD of the free space to draw nothing,
/// and the mark got a third rather than what it needed. Measured before
/// the change: the wordmark rendered 17.8 pixels wide at 412 — and was
/// still cut to 133 against its natural 165 at 760, which is the
/// DESKTOP breakpoint, so this was never only a phone problem.
///
/// Two changes, and the second is the one worth arguing about.
///
/// The Spacer is gone and the mark is the `Expanded`: it absorbs the
/// free space, which pushes the buttons right exactly as before, and
/// the mark draws from its left edge with room to spare.
///
/// And the word is now drawn WHOLE OR NOT AT ALL. Six letters of a
/// brand name says less than the logo beside it and reads as a
/// rendering fault; a `LayoutBuilder` measures what the word needs and
/// the logo carries the brand alone when it will not fit. Measured
/// rather than given a breakpoint, because the wordmark is an
/// operator's setting — "iA" and "Perakaunan Sinar Sdn Bhd" want to
/// disappear at very different widths.
void main() {
  LandingContent brand({String wordmark = 'iAkauntan'}) => LandingContent(
    published: true,
    wordmark: wordmark,
    barSignInMobile: true,
    barRegisterMobile: true,
  );

  Future<void> pump(
    WidgetTester tester,
    double width, {
    String wordmark = 'iAkauntan',
  }) async {
    tester.view.physicalSize = Size(width, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => MediaQuery(
              // Reduce-motion, so the reveal animations leave no timers
              // pending past the end of the test.
              data: MediaQuery.of(context).copyWith(disableAnimations: true),
              child: LandingPage(content: brand(wordmark: wordmark), preview: true),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
  }

  /// The wordmark inside the masthead's mark, if it is drawn at all.
  Finder word(String wordmark) => find.descendant(
    of: find.byType(LandingMark).first,
    matching: find.text(wordmark),
  );

  group('a bar with room', () {
    for (final width in [1280.0, 900.0, 760.0, 600.0]) {
      testWidgets('draws the whole name at ${width.toInt()}', (tester) async {
        // Not "draws a name". The assertion is that the rendered text is
        // the full string — `find.text` is exact, so a truncated
        // "iAka…" does not match it. That is the whole report.
        await pump(tester, width);

        expect(word('iAkauntan'), findsOneWidget);
      });
    }

    testWidgets('and gives it the width it actually needs', (tester) async {
      // The Spacer used to take a third of the row to draw nothing.
      // 165 is what this word wants; anything much under that is the
      // old arrangement back again.
      await pump(tester, 1280);

      expect(tester.getSize(word('iAkauntan')).width, greaterThan(160));
    });
  });

  group('a bar without room', () {
    for (final width in [412.0, 360.0]) {
      testWidgets('drops the name rather than cutting it at '
          '${width.toInt()}', (tester) async {
        await pump(tester, width);

        // The logo is still there and carries the brand on its own.
        expect(find.byType(LandingMark), findsWidgets);
        expect(word('iAkauntan'), findsNothing);
      });
    }

    testWidgets('and a long name disappears sooner than a short one',
        (tester) async {
      // The reason this is measured rather than given a breakpoint. At
      // 600 the default name fits and a long one cannot, and no single
      // number is right for both.
      await pump(tester, 600);
      expect(word('iAkauntan'), findsOneWidget);

      await pump(tester, 600, wordmark: 'Perakaunan Sinar Sendirian Berhad');
      expect(word('Perakaunan Sinar Sendirian Berhad'), findsNothing);
    });

    testWidgets('and a very short one survives a phone', (tester) async {
      // The other end of the same rule, and the control for the two
      // assertions above: without it, "the name is dropped on a phone"
      // passes against a masthead that never draws a name at all.
      await pump(tester, 412, wordmark: 'iA');

      expect(word('iA'), findsOneWidget);
    });
  });

  group('the bar itself', () {
    for (final width in [1280.0, 900.0, 760.0, 600.0, 412.0, 360.0]) {
      testWidgets('fits at ${width.toInt()}', (tester) async {
        // A `RenderFlex` overflow IS a test failure, and the masthead
        // is a Row of a burger, a mark and up to two buttons.
        await pump(tester, width);

        expect(find.byType(LandingMark), findsWidgets);
      });
    }
  });
}
