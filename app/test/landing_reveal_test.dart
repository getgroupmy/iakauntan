import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/features/landing/landing_motion.dart';

/// Content below the fold has to become visible.
///
/// `RevealOnScroll` starts every child at opacity zero and fades it in
/// when it scrolls into view. The probe that decided "in view" was a
/// `NotificationListener<ScrollNotification>` wrapped around the child
/// — and scroll notifications travel *up* the tree from the
/// `Scrollable` that sends them, so a listener sitting inside the
/// scroll view is below the sender and never hears one.
///
/// The only thing that ever fired was a post-frame check on arrival,
/// true exactly for what was on screen at the first frame. Everything
/// under it stayed at opacity zero permanently: laid out, occupying its
/// full height, invisible. On a phone that was the whole page below a
/// blank gap the size of the content that should have filled it.
///
/// Reported from a phone, not caught here, which is what this file is
/// for. The assertion is deliberately about opacity rather than about
/// which widget listens to what: a future rewrite is free to reveal
/// content any way it likes, and is not free to leave it invisible.
void main() {
  Future<void> pumpPage(WidgetTester tester, ScrollController controller) {
    return tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            controller: controller,
            child: Column(
              children: [
                // Taller than the viewport, so what follows starts well
                // out of sight — the hero's job on a phone.
                const SizedBox(height: 2000, child: Text('above')),
                RevealOnScroll(child: Container(key: const Key('card'))),
              ],
            ),
          ),
        ),
      ),
    );
  }

  double opacityOf(WidgetTester tester) => tester
      .widgetList<Opacity>(
        find.ancestor(
          of: find.byKey(const Key('card')),
          matching: find.byType(Opacity),
        ),
      )
      .first
      .opacity;

  testWidgets('a card below the fold is invisible until it is reached', (
    tester,
  ) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    await pumpPage(tester, controller);
    await tester.pumpAndSettle();

    // Still hidden, which is the point of the effect.
    expect(opacityOf(tester), 0);
  });

  testWidgets('and becomes visible once it is scrolled to', (tester) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    await pumpPage(tester, controller);
    await tester.pumpAndSettle();

    controller.jumpTo(1900);
    await tester.pump();
    await tester.pumpAndSettle();

    expect(
      opacityOf(tester),
      1,
      reason: 'content below the fold never faded in — the whole page '
          'under the hero would be a blank gap',
    );
  });

  testWidgets('and nothing is hidden when there is nothing to scroll', (
    tester,
  ) async {
    // A preview pane, a short page, a test. There is no scrollable to
    // listen to, so waiting for a scroll event would wait forever —
    // invisible for good is a far worse failure than un-animated.
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: RevealOnScroll(child: Container(key: const Key('card'))),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(opacityOf(tester), 1);
  });
}
