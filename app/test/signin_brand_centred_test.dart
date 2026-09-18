import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iakauntan/src/data/reserved_names_repository.dart';
import 'package:iakauntan/src/data/site_pages_repository.dart';
import 'package:iakauntan/src/features/auth/sign_in_screen.dart';
import 'package:iakauntan/src/features/landing/landing_content.dart';

/// Where the mark sits on the sign-in page, and that it stays there.
///
/// On the two-column layout it heads a column of copy and belongs on
/// the same left edge as the rest of it. On one column it is alone
/// above a form, on an otherwise symmetrical page, and pinned to the
/// left edge it reads as a mark that has slipped rather than a mark
/// that was placed.
///
/// Asserted by MEASURING it rather than by finding a `Center`, because
/// a `Center` around a child the Column has stretched to full width
/// centres nothing -- the child already fills the row and its contents
/// stay wherever they were. That is not hypothetical: the form Column
/// is `CrossAxisAlignment.stretch` precisely so the fields and buttons
/// fill the width, and the first thing anybody reaches for here is
/// relaxing that, which narrows every control on the page.
void main() {
  Widget wrap() => ProviderScope(
    overrides: [
      landingContentProvider.overrideWith(
        (ref) async => const LandingContent(
          published: true,
          // The WORDMARK rather than the logo, and deliberately: an
          // `Image.network` in a test binding gets a 400 and collapses
          // to nothing through its own errorBuilder, so a logo-only
          // fixture has no mark to measure at all. No `logoUrl` is
          // given either, so the image branch is skipped rather than
          // drawn-and-collapsed -- which would leave the 12px gap
          // beside it and shift the text off the centre it is being
          // measured against.
          signinShowName: true,
          signinShowHeadline: true,
          signinHeadline: 'Books that keep themselves',
          wordmark: 'iAkauntan',
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

  /// How tall the status bar and the camera cut-out are on this
  /// pretend device.
  ///
  /// 59 is an iPhone with a Dynamic Island. The default in a test is
  /// ZERO, which is the one value that makes a missing `SafeArea` look
  /// correct -- so a test that did not set this would pass against the
  /// exact layout that was reported.
  const notch = 59.0;

  Future<void> at(
    WidgetTester tester,
    Size size, {
    double topInset = notch,
  }) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = size;
    tester.view.padding = FakeViewPadding(top: topInset);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();
  }

  final brand = find.byKey(const ValueKey('signin-brand'));

  /// How far the mark's own centre is from the centre of the form it
  /// sits above.
  ///
  /// Measured against the FORM rather than against the screen: the
  /// column is capped at 400 wide and centred in whatever space there
  /// is, so on a wide-but-single-column phone held sideways the two
  /// centres are the same point and the screen's is not.
  double offsetFromFormCentre(WidgetTester tester) {
    final mark = tester.getRect(
      find.descendant(of: brand, matching: find.text('iAkauntan')),
    );
    final field = tester.getRect(
      find.widgetWithText(TextFormField, 'Email').first,
    );
    return (mark.center.dx - field.center.dx).abs();
  }

  group('on one column', () {
    testWidgets('the mark is centred over the form', (tester) async {
      await at(tester, const Size(412, 915));

      expect(brand, findsOneWidget);
      // A pixel of slack for rounding, and no more. The left-aligned
      // arrangement this replaces puts it about 80 out on this width,
      // so the tolerance cannot accidentally admit it.
      expect(offsetFromFormCentre(tester), lessThan(1.0));
    });

    testWidgets('and still centred on a phone held sideways', (tester) async {
      // 915 across is wider than the 900 the second column wants, and
      // this is still one column -- see `signin_landscape_test.dart`.
      // The mark follows the form, not the screen.
      await at(tester, const Size(915, 412));

      expect(brand, findsOneWidget);
      expect(offsetFromFormCentre(tester), lessThan(1.0));
    });

    testWidgets('the mark clears the status bar and the camera', (
      tester,
    ) async {
      // Reported from an iPhone: `Scaffold(body:)` with no app bar lays
      // its child out UNDER the status bar, so the wordmark was drawn
      // through the clock and behind the Dynamic Island.
      await at(tester, const Size(412, 915));

      final mark = tester.getRect(brand);
      expect(mark.top, greaterThanOrEqualTo(notch));
    });

    testWidgets('and stays put when the form is scrolled', (tester) async {
      // A short viewport so there is something to scroll -- the sign-up
      // form is eleven fields long and the mark used to be gone by the
      // second of them.
      await at(tester, const Size(412, 500));

      final before = tester.getRect(brand);
      await tester.drag(
        find.byType(SingleChildScrollView).first,
        const Offset(0, -260),
      );
      await tester.pump();

      expect(tester.getRect(brand), before);
    });

    testWidgets('the fields are still full width', (tester) async {
      // The thing centring the mark must not have cost. Relaxing the
      // Column's `stretch` would centre the mark and narrow every
      // field and button on the page to its own content, which on a
      // phone is a "Sign in" button the width of the words.
      await at(tester, const Size(412, 915));

      final field = tester.getRect(
        find.widgetWithText(TextFormField, 'Email').first,
      );
      final button = tester.getRect(
        find.widgetWithText(FilledButton, 'Sign in').first,
      );
      // 412 across less 24 of padding each side. The BUTTON is the
      // one that gives the mutation away: a text field carries its own
      // width from its decoration and stays wide even unstretched,
      // while a FilledButton shrinks to the two words in it -- which
      // is why asserting only the field let this through.
      expect(field.width, greaterThan(350));
      expect(button.width, greaterThan(350));
      expect(button.width, field.width);
    });
  });

  group('on two columns', () {
    testWidgets('the one-column mark is not drawn at all', (tester) async {
      // The panel carries its own, on its own left edge. Two marks on
      // one page is the failure this key would otherwise hide.
      await at(tester, const Size(1440, 760));

      expect(brand, findsNothing);
      expect(find.byKey(const Key('signin-panel')), findsOneWidget);
    });

    // AN EQUIVALENT MUTANT LIVES HERE, and it is recorded rather than
    // chased. Removing the `!wide` guard from `brandHeader` kills no
    // assertion, and no assertion can be written that it would kill.
    //
    // The header is built only when `_showLogo || _showName`. The panel
    // is skipped only when `hero.isEmpty`, which is
    // `!showLogo && !showName && headline == null && points.isEmpty` --
    // built from those same two fields. So the one branch that would
    // draw a phone header on a desktop, wide-with-no-panel, is exactly
    // the branch in which there is no mark to draw. The two conditions
    // are complements and cannot both hold.
    //
    // The guard stays. It costs nothing, it says what is meant, and it
    // is the only thing standing between this layout and a mark adrift
    // in the middle of a 1440-wide page the day somebody gives the hero
    // a fifth field that does not come from these two.
  });

  group('when the operator has turned it off', () {
    testWidgets('nothing is centred, because nothing is drawn', (tester) async {
      // `signin_show_logo` off and no workspace: the block is absent
      // rather than empty, so a centred empty Row cannot push the
      // heading down a line.
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(412, 915);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            landingContentProvider.overrideWith(
              (ref) async => const LandingContent(published: true),
            ),
            workspaceHostProvider.overrideWith((ref) async => null),
            sitePagesProvider.overrideWith((ref) async => const {}),
            workspaceLookupProvider.overrideWith(
              (ref) async => (host: WorkspaceHost.platform, workspace: null),
            ),
          ],
          child: const MaterialApp(home: SignInScreen()),
        ),
      );
      await tester.pumpAndSettle();

      expect(brand, findsNothing);
    });
  });
}
