import 'package:iakauntan/src/data/site_pages_repository.dart';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iakauntan/src/data/reserved_names_repository.dart';
import 'package:iakauntan/src/features/auth/sign_in_screen.dart';
import 'package:iakauntan/src/features/landing/landing_content.dart';

/// What the sign-in page offers at a company's own address.
///
/// Everything below the Sign in button is about joining the platform,
/// and none of it belongs on Sinar's door. This was checked by looking
/// at a screenshot and the screenshot was of a stale bundle, which is
/// exactly the reason to assert it instead.
void main() {
  // The sign-in screen is two columns on a wide window and the demo
  // list is long. At the default 800x600 test surface it overflows and
  // the failure is about pixels rather than about what is on the page.
  setUp(() {
    final view = TestWidgetsFlutterBinding.ensureInitialized().platformDispatcher
        .views.first;
    view.physicalSize = const Size(1600, 2400);
    view.devicePixelRatio = 1.0;
  });
  tearDown(() {
    final view = TestWidgetsFlutterBinding.ensureInitialized().platformDispatcher
        .views.first;
    view.resetPhysicalSize();
    view.resetDevicePixelRatio();
  });

  // `signinShowRegister` is on throughout, because what is asserted
  // here is the company-door rule and not `0336`'s switch: with the
  // switch off the link is absent everywhere, and "absent on Sinar's
  // door" would pass without the rule existing at all.
  Widget wrap({Map<String, dynamic>? workspace}) => ProviderScope(
        overrides: [
          workspaceHostProvider.overrideWith((ref) async => workspace),
          workspaceLookupProvider.overrideWith(
            (ref) async => workspace == null
                ? (host: WorkspaceHost.platform, workspace: null)
                : (host: WorkspaceHost.found, workspace: workspace),
          ),
          landingContentProvider.overrideWith(
            (ref) async => const LandingContent(
              published: true,
              signinShowRegister: true,
            ),
          ),
        ],
        child: const MaterialApp(home: SignInScreen()),
      );

  testWidgets('a company door offers no way to join the platform',
      (tester) async {
    await tester.pumpWidget(wrap(workspace: {'name': 'Sinar Teknologi Sdn Bhd'}));
    await tester.pumpAndSettle();

    expect(find.textContaining('Create an account'), findsNothing);
    expect(find.textContaining('look around a demo'), findsNothing);
    expect(find.textContaining('Owner'), findsNothing);
  });

  testWidgets('and says whose door it is', (tester) async {
    await tester.pumpWidget(wrap(workspace: {'name': 'Sinar Teknologi Sdn Bhd'}));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('Sinar Teknologi Sdn Bhd'),
      findsWidgets,
      reason: 'the whole point of the page is that it is theirs',
    );
  });

  testWidgets('the bare domain keeps both', (tester) async {
    // The other half of the assertion. Hiding these everywhere would
    // pass the test above and take the front door off the product.
    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();

    expect(find.textContaining('Create an account'), findsWidgets);
  });

  group('the email, asked before the password', () {
    // `0347`. A company's door is for a known set of people, so the
    // form asks who is there first — and a shift standing at a counter
    // is told "User not found" instead of typing a password that was
    // never going to be taken.
    //
    // Only the shape is asserted here. Which emails get through is the
    // database's rule and `supabase/tests/email_before_password.sql`
    // holds it, including the part that matters most: every address
    // that is not for anybody in particular answers yes to everybody.
    testWidgets('a company door asks for the email alone', (tester) async {
      await tester.pumpWidget(wrap(workspace: const {'name': 'Sinar'}));
      await tester.pumpAndSettle();

      expect(find.text('Continue'), findsOneWidget);
      expect(find.text('Password'), findsNothing);
      expect(find.text('Forgot password?'), findsNothing);
    });

    testWidgets('and the bare domain asks for both at once', (tester) async {
      await tester.pumpWidget(wrap());
      await tester.pumpAndSettle();

      // Nobody at `iakauntan.com` is not one of a known set of people,
      // so there is nothing to ask and no reason to make anybody press
      // twice.
      expect(find.text('Continue'), findsNothing);
      expect(find.text('Password'), findsOneWidget);
    });
  });

  group('the hold around a sign-in', () {
    // The ordering, asserted directly, because the ordering is what
    // nothing could see: `vettingProvider` was declared and the router
    // honoured it while, for one commit, nothing raised it. A rebase
    // resolved a conflict in the sign-in screen in favour of an older
    // copy and took the two lines with it. Everything compiled, every
    // test passed, and the app went back to letting people in and
    // throwing them out again.
    test('goes up before the password leaves, and down after vetting', () async {
      final order = <String>[];

      await vettedSignIn(
        hold: (held) => order.add(held ? 'hold' : 'release'),
        signIn: () async => order.add('signIn'),
        vet: () async => order.add('vet'),
      );

      expect(order, ['hold', 'signIn', 'vet', 'release']);
    });

    test('and comes down even when signing in throws', () async {
      final order = <String>[];

      await expectLater(
        vettedSignIn(
          hold: (held) => order.add(held ? 'hold' : 'release'),
          signIn: () async => throw Exception('wrong password'),
          vet: () async => order.add('vet'),
        ),
        throwsException,
      );

      // A hold nobody lifts is an app that never moves again, so the
      // release matters more here than anywhere. And vetting is skipped
      // — there is no session to ask about.
      expect(order, ['hold', 'release']);
    });

    test('and even when the vetting itself throws', () async {
      final order = <String>[];

      await expectLater(
        vettedSignIn(
          hold: (held) => order.add(held ? 'hold' : 'release'),
          signIn: () async => order.add('signIn'),
          vet: () async => throw Exception('the lookup fell over'),
        ),
        throwsException,
      );

      expect(order, ['hold', 'signIn', 'release']);
    });
  });

  group('what a refusal says', () {
    // Pure, and separate from the round trip, because the interesting
    // case is the one where the round trip has not finished: the name
    // comes from a lookup that may still be in flight when the refusal
    // lands, and "not on 's team" reads as a bug rather than an answer.
    test('names the company whose door it is', () {
      expect(
        notTheirDoorMessage('Sinar Teknologi'),
        contains("not on Sinar Teknologi's team"),
      );
    });

    test('and says something sensible when it has no name', () {
      final said = notTheirDoorMessage(null);

      expect(said, contains('may not use this address'));
      expect(said, isNot(contains("'s team")));
    });

    test('either way it says where to go instead', () {
      expect(notTheirDoorMessage('Sinar'), contains('iakauntan.com'));
      expect(notTheirDoorMessage(null), contains('iakauntan.com'));
    });
  });

  // The dialog itself is deliberately not pumped here, and that is a
  // retreat rather than a decision I like.
  //
  // Three tests did pump it — open `showRefusal`, assert the title and
  // the message, tap OK. They passed in four seconds when this file was
  // run alone and hung until the ten-minute per-test timeout when the
  // whole suite ran, taking CI's twenty-minute job down with them.
  // Neither holding and awaiting the dialog's future nor pumping a
  // fixed number of frames instead of `pumpAndSettle` fixed it:
  // something on this screen does not reach quiescence with a route
  // above it, and I did not find what.
  //
  // A flaky test that can hang a twenty-minute job is worse than no
  // test — it costs every future run and teaches everyone to re-run
  // rather than to read. So what is asserted here is the wording, which
  // is pure and cannot hang, and `sign_in_screen.dart` keeps
  // `showRefusal` as its own method so whoever works out the quiescence
  // problem has a seam to pump.

  group('nothing before the operator\'s page has landed', () {
    // The complaint: for a split second the sign-in page is the one we
    // shipped — our labels, no logo, no panel — and then it becomes the
    // one the operator wrote. Every switch on this screen already reads
    // "not yet known" as "do not draw", which is why the headline and
    // the register link do not flicker. The *labels* have no switch:
    // `_brand?.signinEmailLabel ?? 'Email'` has to draw something, and
    // until the payload lands the something is ours.
    Widget waiting({Completer<LandingContent>? landing}) => ProviderScope(
          overrides: [
            workspaceHostProvider.overrideWith((ref) async => null),
            workspaceLookupProvider.overrideWith(
              (ref) async => (host: WorkspaceHost.platform, workspace: null),
            ),
            sitePagesProvider.overrideWith((ref) async => const {}),
            landingContentProvider.overrideWith(
              (ref) => (landing ?? Completer<LandingContent>()).future,
            ),
          ],
          child: const MaterialApp(home: SignInScreen()),
        );

    testWidgets('draws no form at all', (tester) async {
      await tester.pumpWidget(waiting());
      await tester.pump();

      expect(find.byType(TextFormField), findsNothing);
      expect(find.text('Email'), findsNothing);
      expect(find.text('Sign in'), findsNothing);
    });

    testWidgets('and the operator\'s words are the only ones ever seen',
        (tester) async {
      final landing = Completer<LandingContent>();
      await tester.pumpWidget(waiting(landing: landing));
      await tester.pump();

      expect(find.text('Email'), findsNothing);

      landing.complete(const LandingContent(
        published: true,
        signinEmailLabel: 'Work email',
      ));
      await tester.pumpAndSettle();

      expect(find.text('Work email'), findsOneWidget);
      expect(find.text('Email'), findsNothing);
    });
  });

  group('the login page, which is a door of its own', () {
    // `0348`. The same screen at a company's own address, reading a
    // second row of copy rather than the platform's.
    //
    // Two audiences and one row of words was the problem: `signin` is
    // written for somebody at `iakauntan.com` who may not have an
    // account yet, and nobody arriving at `sinar.iakauntan.com` is
    // wondering what the product is. An operator could write for one of
    // them or the other and not for both.
    //
    // A scope on the existing screen and not a second screen, which is
    // what makes this worth asserting: the wiring is one getter, and a
    // getter that reads the wrong slug is invisible until somebody
    // edits a page and watches nothing change.
    Widget wrapScoped(SignInScope scope) => ProviderScope(
          overrides: [
            workspaceHostProvider.overrideWith(
              (ref) => const {'name': 'Sinar Teknologi Sdn Bhd'},
            ),
            workspaceLookupProvider.overrideWith(
              (ref) => (
                host: WorkspaceHost.found,
                workspace: const {'name': 'Sinar Teknologi Sdn Bhd'},
              ),
            ),
            landingContentProvider.overrideWith(
              (ref) => const LandingContent(
                published: true,
                signinShowHeading: true,
              ),
            ),
            sitePagesProvider.overrideWith(
              (ref) => const {
                'signin': SitePage(
                  slug: 'signin',
                  title: 'The platform desk',
                  body: 'Sign in to',
                  isPublished: false,
                ),
                'login': SitePage(
                  slug: 'login',
                  title: 'The company desk',
                  body: 'Sign in to',
                  isPublished: false,
                ),
              },
            ),
          ],
          child: MaterialApp(home: SignInScreen(scope: scope)),
        );

    testWidgets('draws its own words, not the platform\'s',
        (tester) async {
      await tester.pumpWidget(wrapScoped(SignInScope.workspace));
      await tester.pumpAndSettle();

      expect(find.text('The company desk'), findsOneWidget);
      expect(find.text('The platform desk'), findsNothing);
    });

    testWidgets('and the platform door still draws the platform\'s',
        (tester) async {
      await tester.pumpWidget(wrapScoped(SignInScope.platform));
      await tester.pumpAndSettle();

      expect(find.text('The platform desk'), findsOneWidget);
      expect(find.text('The company desk'), findsNothing);
    });
  });

  group('and the company writes its own words on it', () {
    // `0349`. The platform's `login` row is one sentence for every
    // tenant at once, which is to say a generic one. The words over
    // Sinar's door are Sinar's, and they arrive on the workspace lookup
    // — the call this screen already makes for the name and the mark.
    //
    // Field by field, which is the part worth pinning: a company that
    // wrote a heading and left the lead-in alone keeps ours underneath
    // theirs. Row-by-row precedence would silently blank the half they
    // did not touch, and it would look like the save had eaten it.
    Widget wrapDoor({String? title, String? body}) => ProviderScope(
          overrides: [
            workspaceHostProvider.overrideWith(
              (ref) => {
                'name': 'Sinar Teknologi Sdn Bhd',
                'login_title': title,
                'login_body': body,
              },
            ),
            workspaceLookupProvider.overrideWith(
              (ref) => (
                host: WorkspaceHost.found,
                workspace: const {'name': 'Sinar Teknologi Sdn Bhd'},
              ),
            ),
            landingContentProvider.overrideWith(
              (ref) => const LandingContent(
                published: true,
                signinShowHeading: true,
              ),
            ),
            sitePagesProvider.overrideWith(
              (ref) => const {
                'login': SitePage(
                  slug: 'login',
                  title: 'The platform wrote this',
                  body: 'Sign in to continue to',
                  isPublished: false,
                ),
              },
            ),
          ],
          child: const MaterialApp(
            home: SignInScreen(scope: SignInScope.workspace),
          ),
        );

    testWidgets('a heading of its own wins', (tester) async {
      await tester.pumpWidget(wrapDoor(title: 'Masuk ke Sinar'));
      await tester.pumpAndSettle();

      expect(find.text('Masuk ke Sinar'), findsOneWidget);
      expect(find.text('The platform wrote this'), findsNothing);
    });

    testWidgets('and the half it did not write is still ours',
        (tester) async {
      await tester.pumpWidget(wrapDoor(title: 'Masuk ke Sinar'));
      await tester.pumpAndSettle();

      expect(
        find.text('Sign in to continue to Sinar Teknologi Sdn Bhd.'),
        findsOneWidget,
      );
    });

    testWidgets('a lead-in of its own wins too, in front of the name',
        (tester) async {
      await tester.pumpWidget(
        wrapDoor(body: 'Log masuk untuk teruskan ke'),
      );
      await tester.pumpAndSettle();

      // The name is never typed by an operator — platform-wide copy
      // cannot say "Sinar" — so what they write goes in front of it.
      expect(
        find.text('Log masuk untuk teruskan ke Sinar Teknologi Sdn Bhd.'),
        findsOneWidget,
      );
      expect(find.text('The platform wrote this'), findsOneWidget);
    });

    testWidgets('and a company that wrote nothing gets ours', (tester) async {
      await tester.pumpWidget(wrapDoor());
      await tester.pumpAndSettle();

      expect(find.text('The platform wrote this'), findsOneWidget);
      expect(
        find.text('Sign in to continue to Sinar Teknologi Sdn Bhd.'),
        findsOneWidget,
      );
    });
  });
}
