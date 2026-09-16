import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iakauntan/src/data/reserved_names_repository.dart';
import 'package:iakauntan/src/data/site_pages_repository.dart';
import 'package:iakauntan/src/features/auth/sign_in_screen.dart';
import 'package:iakauntan/src/features/landing/landing_content.dart';

/// Which layout a sign-in page gets, and why it is not a question about
/// width.
///
/// Reported from a real Android phone: at 915 by 412 — an ordinary
/// handset held sideways — the page switched to the two-column DESKTOP
/// layout, and the Sign in button ended up below the fold. Half the
/// screen was a decorative panel and the one control the page exists
/// for was off it.
///
/// The test was `width >= 900`, and 915 is over 900. But the thing that
/// decides whether two columns fit is not how wide the screen is; it is
/// what KIND of screen it is, and a phone is a phone whichever way up
/// it is held. `shortestSide` does not change when the device rotates,
/// which is exactly the property wanted here.
///
/// 900 stays the number. A laptop is at least 900 both ways round; a
/// tablet in portrait is about 800, which is the line this always meant
/// to draw and never did.
void main() {
  Widget wrap() => ProviderScope(
    overrides: [
      landingContentProvider.overrideWith(
        // Enough for the panel to have something to draw. A wide
        // window with an EMPTY panel gets no panel either, by design,
        // so an empty brand would make every assertion below pass for
        // the wrong reason.
        // `signinShowHeadline` as well as the headline itself: the
        // panel reads the SWITCH, and a headline with the switch off is
        // a panel with nothing in it. A wide window with an empty panel
        // draws no panel by design, so getting this wrong makes every
        // "no panel" assertion below pass for the wrong reason -- which
        // is what the first draft of this file did.
        (ref) async => const LandingContent(
          published: true,
          signinShowHeadline: true,
          signinHeadline: 'Books that keep themselves',
          signinShowLogo: true,
          // The points, which are the thing that was reported missing.
          // The panel's own key can be present while the list inside it
          // is empty, and an empty fixture cannot tell the two apart --
          // so the earlier version of this file asserted the container
          // and never the contents.
          signinPoints: [
            (
              icon: null,
              title: 'LHDN e-Invoice built in',
              body: 'Submit to MyInvois and track validation without '
                  'leaving your books.',
            ),
            (
              icon: null,
              title: 'Double-entry you can trust',
              body: 'Every invoice, bill and payment posts to a balanced '
                  'ledger.',
            ),
          ],
        ),
      ),
      workspaceHostProvider.overrideWith((ref) async => null),
      sitePagesProvider.overrideWith((ref) async => const {}),
      workspaceLookupProvider.overrideWith(
        (ref) async => (host: WorkspaceHost.platform, workspace: null),
      ),
    ],
    child: const MaterialApp(home: SignInScreen()),
  );

  Future<void> at(WidgetTester tester, Size size) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = size;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();
  }

  /// The decorative half. Present only in the two-column layout.
  final panel = find.byKey(const Key('signin-panel'));

  group('a phone', () {
    testWidgets('gets one column upright', (tester) async {
      await at(tester, const Size(412, 915));

      expect(panel, findsNothing);
    });

    testWidgets('and one column on its side, which is the report',
        (tester) async {
      // The same device, rotated. 915 is wider than 900 and this is
      // still a phone.
      await at(tester, const Size(915, 412));

      expect(panel, findsNothing);
      // The other side of it: on one column the points are not drawn
      // anywhere else either, so this is not a panel that merely moved.
      expect(find.text('LHDN e-Invoice built in'), findsNothing);
    });
  });

  group('a tablet', () {
    testWidgets('gets one column in portrait', (tester) async {
      // 800 across is under the 900 the second column needs.
      await at(tester, const Size(800, 1280));

      expect(panel, findsNothing);
    });
  });

  group('a laptop', () {
    // THE SIZES HERE ARE THE POINT, and the first version of this file
    // got them wrong in a way that let a regression through.
    //
    // Its desktop control was 1440x900 -- exactly on the boundary -- and
    // 1024x1600, a window taller than it is wide. Neither is a laptop.
    // A browser viewport on a 1440x900 screen is about 1440x760 once the
    // chrome is off it, and on a 1366x768 laptop it is nearer 1366x630.
    //
    // So when the breakpoint was briefly `shortestSide >= 900` alone,
    // every one of those heights fell under it, the panel came off every
    // desktop, and this file stayed green. It had also asserted that
    // 1280x800 gets ONE column -- which is the shape of a laptop
    // viewport, so the test was pinning the defect in place.
    //
    // Real viewports now, measured from the browser rather than from the
    // screen it is running on.
    for (final size in const [
      Size(1440, 760), // 15" laptop, browser chrome removed
      Size(1366, 630), // the commonest laptop panel there is
      Size(1280, 720),
      Size(1920, 1080), // an external monitor
      Size(1024, 700), // a small window on a big screen
    ]) {
      testWidgets(
          'gets the panel at ${size.width.toInt()}x${size.height.toInt()}',
          (tester) async {
        await at(tester, size);

        expect(panel, findsOneWidget);
        // And what is IN it. The report was not "the panel is missing",
        // it was that the points beside the form had gone.
        expect(find.text('LHDN e-Invoice built in'), findsOneWidget);
        expect(find.text('Double-entry you can trust'), findsOneWidget);
        expect(find.text('Books that keep themselves'), findsOneWidget);
      });
    }

    testWidgets('and a tall narrow window does not, because the second '
        'column has nowhere to go', (tester) async {
      // Height is not what the panel needs. 800 across is 800 across.
      await at(tester, const Size(800, 1600));

      expect(panel, findsNothing);
    });
  });

  testWidgets('and the button the page exists for is reachable on a phone '
      'in landscape', (tester) async {
    // The actual complaint. One column is only the mechanism; what
    // matters is that Sign in is on the screen rather than under it.
    await at(tester, const Size(915, 412));

    final button = find.widgetWithText(FilledButton, 'Sign in');
    expect(button, findsOneWidget);

    await tester.ensureVisible(button);
    await tester.pumpAndSettle();

    final box = tester.getRect(button);
    expect(box.bottom, lessThanOrEqualTo(412));
  });
}
