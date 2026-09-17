import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/features/landing/landing_content.dart';
import 'package:iakauntan/src/features/landing/landing_screen.dart';

/// Where the hero copy sits in its band.
///
/// The band has a floor — 620 on a desktop, 560 on a phone — so a hero
/// with a picture behind it is a band rather than a strip. The copy is
/// meant to sit in the middle of it.
///
/// It stopped doing that, and the way it stopped is worth writing down
/// because it looked like nothing. The floor was moved from a
/// `SizedBox(height:)` onto the band to fix a four-pixel overflow on a
/// narrow phone, and a `Stack` measures its one unpositioned child
/// loose: the copy sized to its own content and was parked at the
/// stack's alignment, which is the top left. So the headline sat at the
/// top of a 620-pixel band with four hundred pixels of dead photograph
/// under it — the same shape of complaint as the blank gap between the
/// bands, arriving by a different route, and invisible to every test
/// there was because nothing was missing and nothing overflowed.
///
/// The fix is to put the floor on the copy instead. Asserted here on
/// geometry rather than on which widget carries the constraint, so the
/// layout stays free to change and the copy stays in the middle.
void main() {
  Future<void> pump(WidgetTester tester, {required bool wide}) async {
    tester.view.physicalSize = Size(wide ? 1440 : 420, wide ? 1000 : 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => MediaQuery(
              data: MediaQuery.of(context).copyWith(disableAnimations: true),
              child: const LandingPage(
                // A hero picture is what puts the page on the
                // full-bleed path at all; without one it draws the
                // two-column shape and this band does not exist.
                content: LandingContent(
                  published: true,
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

  /// The band, found by the picture that fills it.
  ///
  /// `Positioned.fill` over the stack, so the hero image's rectangle is
  /// the band's rectangle. Picked by width — the only other `Image` on
  /// the page at this point is the mark in the bar, which is 36 pixels
  /// across.
  Rect band(WidgetTester tester) => find
      .byType(Image)
      .evaluate()
      .map((e) => tester.getRect(find.byWidget(e.widget)))
      .reduce((a, b) => a.width >= b.width ? a : b);

  /// The copy, from the top of the headline to the bottom of the
  /// buttons under it — not the footer's link of the same name, which
  /// is thousands of pixels further down.
  Rect copy(WidgetTester tester) {
    final headline = tester.getRect(find.textContaining('Accounting').first);
    final outer = band(tester);
    // Every way-in button inside the band, not the footer's links of
    // the same names thousands of pixels below — and every one of
    // them, because on a phone the two wrap onto separate rows and
    // measuring to the first makes the copy look half its height.
    final buttons = [
      for (final label in const ['Create an account', 'Sign in'])
        for (final e in find.text(label).evaluate())
          tester.getRect(find.byWidget(e.widget)),
    ].where((r) => r.top >= headline.bottom && r.bottom <= outer.bottom);
    return Rect.fromLTRB(
      headline.left,
      headline.top,
      headline.right,
      buttons.map((r) => r.bottom).reduce((a, b) => a > b ? a : b),
    );
  }

  for (final at in const [
    (wide: true, floor: 620.0),
    (wide: false, floor: 560.0),
  ]) {
    testWidgets('the band is at least its floor, wide: ${at.wide}', (
      tester,
    ) async {
      await pump(tester, wide: at.wide);
      expect(band(tester).height, greaterThanOrEqualTo(at.floor));
    });

    testWidgets('and it holds the copy, wide: ${at.wide}', (tester) async {
      await pump(tester, wide: at.wide);
      final outer = band(tester);
      final inner = copy(tester);
      expect(inner.top, greaterThanOrEqualTo(outer.top));
      expect(inner.bottom, lessThanOrEqualTo(outer.bottom));
    });

    testWidgets('and the copy is in the middle of it, wide: ${at.wide}', (
      tester,
    ) async {
      await pump(tester, wide: at.wide);
      final outer = band(tester);
      final inner = copy(tester);

      final above = inner.top - outer.top;
      final below = outer.bottom - inner.bottom;

      // Centred means as much room above the copy as below it. The
      // failure this catches is all of it below — which is what a
      // `Stack` does to its one unpositioned child when the child is
      // measured loose and parked at the stack's alignment.
      expect(
        (above - below).abs(),
        lessThan(48),
        reason:
            'wide: ${at.wide} — $above above the copy and $below below it, '
            'in a band ${outer.height} tall',
      );
    });
  }
}
