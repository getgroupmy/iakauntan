import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/features/landing/landing_content.dart';
import 'package:iakauntan/src/features/landing/landing_screen.dart';

/// How dark the hero's scrim is, and where.
///
/// Reported from an Android handset: the hero "looks cluttered on
/// phones", with text from the picture behind it — "e-Invoice", "26",
/// "g drafts" — showing through at the left edge.
///
/// The cause is a premise that stops being true on a phone. The scrim
/// is a left-to-right gradient that goes from nearly opaque ink to
/// almost nothing, because the copy is on the LEFT and the picture is
/// meant to carry its subject on the right. On a desktop that is a
/// composition. On a handset the copy is capped at 640 and the screen
/// is 412, so the copy spans the WHOLE width — and the right-hand end
/// of every wrapped line sat over the thinnest twenty per cent of the
/// scrim. The uploaded hero on this deployment is a screenshot of the
/// dashboard, so what came through under the words was other words,
/// which is not a contrast problem but a legibility one.
///
/// So the assertion is about the THINNEST part of the scrim, not the
/// darkest: on a narrow screen no part of it may be thin, and on a wide
/// one it must still thin out, because a scrim that is flat and dark
/// everywhere throws the picture away on the screens that have room to
/// show it. Both directions are asserted here. One of them alone passes
/// against a build that has forgotten the branch entirely and uses the
/// same gradient at every width — which is precisely the defect, in
/// whichever direction it was left.
void main() {
  Future<void> pump(WidgetTester tester, double width) async {
    tester.view.physicalSize = Size(width, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => MediaQuery(
              data: MediaQuery.of(context).copyWith(disableAnimations: true),
              child: const LandingPage(
                // A hero picture is what puts the page on the full-bleed
                // path at all; without one there is no scrim to measure.
                content: LandingContent(
                  published: true,
                  heroHeadline: 'Accounting, payroll and e-Invoice',
                  heroSubhead: 'One ledger for a Malaysian business.',
                  heroImageUrl: 'https://example.test/hero.png',
                ),
                preview: true,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  /// A rectangle straight off the element, in global coordinates.
  ///
  /// Not `tester.getRect(find.byWidget(...))`: several of the page's
  /// `DecoratedBox`es are equal as widgets, and `find.byWidget` matches
  /// by equality, so it would throw on the ones it cannot tell apart.
  Rect rectOf(Element e) {
    final box = e.renderObject! as RenderBox;
    return box.localToGlobal(Offset.zero) & box.size;
  }

  /// The band, found by the picture that fills it — `Positioned.fill`
  /// over the stack, so the hero image's rectangle IS the band's. Picked
  /// by width, the only other `Image` up here being the 36-pixel mark in
  /// the bar.
  Rect band(WidgetTester tester) => find
      .byType(Image)
      .evaluate()
      .map(rectOf)
      .reduce((a, b) => a.width >= b.width ? a : b);

  /// The scrim: the linear gradient drawn across the whole hero band.
  ///
  /// Identified by geometry rather than by position in the tree, so the
  /// stack stays free to be rearranged. A gradient that covered only
  /// part of the band would not be found here, and that is deliberate —
  /// a half-width scrim is the bug, not a variant of the fix.
  LinearGradient scrim(WidgetTester tester) {
    final over = band(tester);
    final found = <LinearGradient>[];
    for (final e in find.byType(DecoratedBox).evaluate()) {
      final decoration = (e.widget as DecoratedBox).decoration;
      if (decoration is! BoxDecoration) continue;
      final gradient = decoration.gradient;
      if (gradient is! LinearGradient) continue;
      final rect = rectOf(e);
      if ((rect.width - over.width).abs() > 1 ||
          (rect.height - over.height).abs() > 1 ||
          (rect.top - over.top).abs() > 1) {
        continue;
      }
      found.add(gradient);
    }
    expect(found, hasLength(1), reason: 'exactly one scrim fills the hero');
    return found.single;
  }

  /// The thinnest stop in the gradient, as an alpha in 0..1.
  double thinnest(LinearGradient g) =>
      g.colors.map((c) => c.a).reduce((a, b) => a < b ? a : b);

  double thickest(LinearGradient g) =>
      g.colors.map((c) => c.a).reduce((a, b) => a > b ? a : b);

  group('on a phone', () {
    for (final width in [360.0, 412.0, 600.0, 760.0]) {
      testWidgets('no part of the scrim is thin at ${width.toInt()}',
          (tester) async {
        await pump(tester, width);

        // 0.8 is the line between "the picture is texture" and "the
        // picture is legible through the words". The shipped floor is
        // 0.86; the gradient that caused the report bottomed out at 0.2.
        expect(thinnest(scrim(tester)), greaterThanOrEqualTo(0.8));
      });
    }

    testWidgets('and it is nearly flat across the width', (tester) async {
      await pump(tester, 412);

      // Dark at the left and dark at the right is not enough on its own
      // — a gradient with a thin MIDDLE would pass the floor above,
      // since that only looks at the stops. The spread is what makes it
      // one wash rather than three.
      final g = scrim(tester);
      expect(thickest(g) - thinnest(g), lessThanOrEqualTo(0.15));
    });
  });

  group('on a desktop', () {
    for (final width in [1440.0, 1100.0, 900.0, 800.0]) {
      testWidgets('the scrim still thins out at ${width.toInt()}',
          (tester) async {
        await pump(tester, width);

        // The other half of the report. Without this a build that made
        // every screen flat and dark would pass the phone tests above
        // and quietly throw away the hero picture on the screens that
        // were never broken.
        expect(thinnest(scrim(tester)), lessThanOrEqualTo(0.4));
      });
    }

    testWidgets('and is darkest where the copy starts', (tester) async {
      await pump(tester, 1440);

      // Left to right, not right to left: the copy is left-aligned in
      // the band and a gradient laid down the other way would satisfy
      // both thresholds above while putting the thin end under the text.
      final g = scrim(tester);
      expect(g.begin, Alignment.centerLeft);
      expect(g.end, Alignment.centerRight);
      expect(g.colors.first.a, thickest(g));
      expect(g.colors.last.a, thinnest(g));
    });
  });

  testWidgets('the scrim is under the copy, not over it', (tester) async {
    await pump(tester, 412);

    // Order in the stack, asserted because getting it wrong is a way to
    // make the headline itself 86% transparent ink — which would read
    // as the same complaint and is not what was asked for.
    final page = find.byType(LandingPage);
    final headline = find.descendant(
      of: page,
      matching: find.text('Accounting, payroll and e-Invoice'),
    );
    expect(headline, findsWidgets);
    final text = tester.widget<Text>(headline.first);
    expect(text.style?.color?.a, 1.0);
  });
}
