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
    });
  });

  group('a tablet', () {
    testWidgets('gets one column in portrait', (tester) async {
      // 800 across is under the line either way round.
      await at(tester, const Size(800, 1280));

      expect(panel, findsNothing);
    });

    testWidgets('and one column in landscape, for the same reason as the '
        'phone', (tester) async {
      await at(tester, const Size(1280, 800));

      expect(panel, findsNothing);
    });
  });

  group('a laptop', () {
    testWidgets('gets the panel, which is the control for all of the '
        'above', (tester) async {
      // Without this the assertions above pass against a build that
      // never draws the panel at all, and the two-column layout would
      // be dead code nobody noticed.
      await at(tester, const Size(1440, 900));

      expect(panel, findsOneWidget);
    });

    testWidgets('and a tall desktop window gets it too', (tester) async {
      await at(tester, const Size(1024, 1600));

      expect(panel, findsOneWidget);
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
