import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iakauntan/src/data/reserved_names_repository.dart';
import 'package:iakauntan/src/data/site_pages_repository.dart';
import 'package:iakauntan/src/features/auth/sign_in_screen.dart';
import 'package:iakauntan/src/features/landing/landing_content.dart';

/// What the sign-in screen draws around the form.
///
/// Before `0336` the answer was "our poster, always": our mark, our
/// headline and three claims about Malaysian e-Invoice, compiled in.
/// Now every piece has a switch and every switch starts off, so the
/// assertions that matter are about the bare page — a switch that
/// quietly defaults on looks exactly like the product working.
void main() {
  Widget wrap(
    LandingContent brand, {
    String? workspaceName,
    Map<String, SitePage> pages = const {},
  }) => ProviderScope(
    overrides: [
      landingContentProvider.overrideWith((ref) async => brand),
      sitePagesProvider.overrideWith((ref) async => pages),
      workspaceLookupProvider.overrideWith(
        (ref) async => workspaceName == null
            ? (host: WorkspaceHost.platform, workspace: null)
            : (
                host: WorkspaceHost.found,
                workspace: <String, dynamic>{'name': workspaceName},
              ),
      ),
    ],
    child: const MaterialApp(home: SignInScreen()),
  );

  setUp(() {
    // The two-column layout needs the room, or the panel overflows and
    // the overflow is what fails rather than the assertion.
    final view = TestWidgetsFlutterBinding.instance.platformDispatcher
        .views
        .first;
    view.physicalSize = const Size(1600, 2400);
    view.devicePixelRatio = 1.0;
    addTearDown(view.reset);
  });

  group('a platform that has switched nothing on', () {
    testWidgets('shows a form and nothing around it', (tester) async {
      await tester.pumpWidget(wrap(LandingContent.fallback));
      await tester.pumpAndSettle();

      expect(find.text('Welcome back'), findsNothing);
      expect(find.textContaining('Accounting and CRM'), findsNothing);
      expect(find.textContaining('LHDN e-Invoice'), findsNothing);
      expect(find.textContaining('Create an account'), findsNothing);

      // The form itself is never optional.
      expect(find.text('Sign in'), findsOneWidget);
      expect(find.text('Email'), findsOneWidget);
    });

    testWidgets('and does not draw an empty panel beside it', (tester) async {
      // Half a screen of flat colour next to a login box is worse than
      // a centred form, so with nothing to put in it the two-column
      // layout is dropped rather than emptied.
      await tester.pumpWidget(wrap(LandingContent.fallback));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('signin-panel')), findsNothing);
    });

    testWidgets('but one switched-on piece brings the panel back',
        (tester) async {
      await tester.pumpWidget(
        wrap(const LandingContent(published: true, signinShowHeadline: true)),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('signin-panel')), findsOneWidget);
    });
  });

  testWidgets('and an answer that has not arrived yet is also nothing',
      (tester) async {
    // Not a detail. Copy that appears a moment after the form has
    // settled reads as a glitch, and "loading" defaulting to "draw it"
    // would put our poster back on every first paint.
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          landingContentProvider.overrideWith(
            (ref) => Completer<LandingContent>().future,
          ),
          sitePagesProvider.overrideWith((ref) async => const {}),
          workspaceLookupProvider.overrideWith(
            (ref) async => (host: WorkspaceHost.platform, workspace: null),
          ),
        ],
        child: const MaterialApp(home: SignInScreen()),
      ),
    );
    await tester.pump();

    expect(find.text('Welcome back'), findsNothing);
    expect(find.textContaining('Create an account'), findsNothing);
    expect(find.byKey(const Key('signin-panel')), findsNothing);
    expect(find.text('Sign in'), findsOneWidget);
  });

  group('the payload the database sends', () {
    // Straight through `parseLandingContent`, because the screen taking
    // a `LandingContent` cannot catch a field that is never read out of
    // the payload — and that failure looks exactly like a console that
    // saves and a page that never changes.
    test('carries the bullets beside brand, not inside page', () {
      final content = parseLandingContent(const {
        'brand': {'signin_show_headline': true},
        'signin_points': [
          {'icon': 'check', 'title': 'One thing', 'body': 'About it.'},
        ],
      });

      // Unpublished — which is the branch that returns early, and the
      // one an operator who has not written a marketing site is on.
      expect(content.published, isFalse);
      expect(content.signinShowHeadline, isTrue);
      expect(content.signinPoints, hasLength(1));
      expect(content.signinPoints.single.title, 'One thing');
    });

    test('and reads them on a published site too', () {
      final content = parseLandingContent(const {
        'page': {'is_published': true},
        'brand': {'signin_show_logo': true, 'signin_show_name': true},
        'signin_points': [
          {'icon': 'check', 'title': 'One thing', 'body': 'About it.'},
        ],
      });

      expect(content.published, isTrue);
      expect(content.signinShowLogo, isTrue);
      expect(content.signinShowName, isTrue);
      expect(content.signinPoints, hasLength(1));
    });

    test('a platform that has said nothing has nothing to draw', () {
      final content = parseLandingContent(const {'brand': {}});

      expect(content.signinShowLogo, isFalse);
      expect(content.signinShowName, isFalse);
      expect(content.signinShowHeadline, isFalse);
      expect(content.signinShowHeading, isFalse);
      expect(content.signinShowRegister, isFalse);
      expect(content.signinPoints, isEmpty);
      expect(content.signinHeadline, isNull);
    });
  });

  group('switched on, one piece at a time', () {
    testWidgets('the heading', (tester) async {
      await tester.pumpWidget(
        wrap(const LandingContent(published: true, signinShowHeading: true)),
      );
      await tester.pumpAndSettle();
      expect(find.text('Welcome back'), findsOneWidget);
    });

    testWidgets('the headline, in the operator\'s own words', (tester) async {
      await tester.pumpWidget(wrap(const LandingContent(
        published: true,
        signinShowHeadline: true,
        signinHeadline: 'Perakaunan untuk perniagaan Malaysia.',
      )));
      await tester.pumpAndSettle();

      expect(find.text('Perakaunan untuk perniagaan Malaysia.'), findsOneWidget);
      expect(find.textContaining('Accounting and CRM'), findsNothing);
    });

    testWidgets('and the shipped words when nobody has written any',
        (tester) async {
      await tester.pumpWidget(
        wrap(const LandingContent(published: true, signinShowHeadline: true)),
      );
      await tester.pumpAndSettle();
      expect(
        find.text(LandingContent.defaultSigninHeadline),
        findsOneWidget,
      );
    });

    testWidgets('the points, and only the ones the database sent',
        (tester) async {
      // The database filters on `is_active`, so an absent point is a
      // point somebody switched off — there is nothing to filter here.
      await tester.pumpWidget(wrap(const LandingContent(
        published: true,
        signinPoints: [
          (icon: 'check', title: 'One thing', body: 'About the one thing.'),
        ],
      )));
      await tester.pumpAndSettle();

      expect(find.text('One thing'), findsOneWidget);
      expect(find.text('About the one thing.'), findsOneWidget);
      expect(find.textContaining('LHDN e-Invoice'), findsNothing);
    });

    testWidgets('a point with no body draws its title alone', (tester) async {
      await tester.pumpWidget(wrap(const LandingContent(
        published: true,
        signinPoints: [(icon: 'check', title: 'Just a title', body: null)],
      )));
      await tester.pumpAndSettle();
      expect(find.text('Just a title'), findsOneWidget);
    });

    testWidgets('the offer of an account', (tester) async {
      await tester.pumpWidget(
        wrap(const LandingContent(published: true, signinShowRegister: true)),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('Create an account'), findsOneWidget);
    });
  });

  group('the heading is three pieces', () {
    // `0342`'s companion change. Two of them are typed and the third is
    // the name, which is the company's at its own door and the
    // platform's everywhere else — so an operator writing the lead-in
    // never has to know whose door it will appear on.
    testWidgets('the shipped lead-in, with the platform name after it',
        (tester) async {
      await tester.pumpWidget(wrap(const LandingContent(
        published: true,
        wordmark: 'Kira Kira',
        signinShowHeading: true,
      )));
      await tester.pumpAndSettle();

      expect(find.text('Welcome back'), findsOneWidget);
      expect(find.text('Sign in to continue to Kira Kira.'), findsOneWidget);
    });

    testWidgets('an operator\'s own lead-in, with the name still after it',
        (tester) async {
      // The half that is theirs. A platform in Malay signs people in
      // with Malay words in front of a name it never had to type.
      await tester.pumpWidget(wrap(
        const LandingContent(
          published: true,
          wordmark: 'Kira Kira',
          signinShowHeading: true,
        ),
        pages: const {
          'signin': SitePage(
            slug: 'signin',
            title: 'Selamat kembali',
            body: 'Log masuk untuk teruskan ke',
          ),
        },
      ));
      await tester.pumpAndSettle();

      expect(find.text('Selamat kembali'), findsOneWidget);
      expect(
        find.text('Log masuk untuk teruskan ke Kira Kira.'),
        findsOneWidget,
      );
      expect(find.textContaining('Sign in to continue'), findsNothing);
    });

    testWidgets('and the company name at its own door', (tester) async {
      await tester.pumpWidget(wrap(
        const LandingContent(
          published: true,
          wordmark: 'Kira Kira',
          signinShowHeading: true,
        ),
        workspaceName: 'Sinar Teknologi',
      ));
      await tester.pumpAndSettle();

      expect(
        find.text('Sign in to continue to Sinar Teknologi.'),
        findsOneWidget,
      );
      expect(find.textContaining('Kira Kira'), findsNothing);
    });
  });

  group('the logo and the name are two decisions', () {
    // `0338`. One switch could not say "the picture but not the word",
    // which is what a platform whose logo already contains its name
    // wants — and that is most of them.
    testWidgets('the name alone draws no logo', (tester) async {
      await tester.pumpWidget(wrap(const LandingContent(
        published: true,
        logoUrl: 'https://example.test/logo.png',
        wordmark: 'Kira Kira',
        signinShowName: true,
      )));
      await tester.pumpAndSettle();

      expect(find.text('Kira Kira'), findsWidgets);
      expect(find.byType(Image), findsNothing);
    });

    testWidgets('the logo alone draws no name', (tester) async {
      await tester.pumpWidget(wrap(const LandingContent(
        published: true,
        logoUrl: 'https://example.test/logo.png',
        wordmark: 'Kira Kira',
        signinShowLogo: true,
      )));
      await tester.pumpAndSettle();

      expect(find.text('Kira Kira'), findsNothing);
      expect(find.byType(Image), findsWidgets);
    });

    testWidgets('and neither draws no panel', (tester) async {
      await tester.pumpWidget(wrap(const LandingContent(
        published: true,
        logoUrl: 'https://example.test/logo.png',
        wordmark: 'Kira Kira',
      )));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('signin-panel')), findsNothing);
    });

    testWidgets('but either one on its own brings the panel back',
        (tester) async {
      await tester.pumpWidget(wrap(const LandingContent(
        published: true,
        wordmark: 'Kira Kira',
        signinShowName: true,
      )));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('signin-panel')), findsOneWidget);
    });
  });

  group("a company's own door", () {
    testWidgets('always gets its mark, whatever the platform switched off',
        (tester) async {
      // The switch is about whether *our* marketing appears. Sinar's
      // logo on Sinar's door is not our marketing, and taking it away
      // because the platform turned its own off is the wrong reading.
      await tester.pumpWidget(
        wrap(LandingContent.fallback, workspaceName: 'Sinar Teknologi'),
      );
      await tester.pumpAndSettle();
      expect(find.text('Sinar Teknologi'), findsWidgets);
    });

    testWidgets('and is never offered an account here', (tester) async {
      // Even with the switch on: an account made at Sinar's door would
      // not be on Sinar's team, and the door policy would then turn it
      // away — a loop the visitor cannot see the shape of.
      await tester.pumpWidget(wrap(
        const LandingContent(published: true, signinShowRegister: true),
        workspaceName: 'Sinar Teknologi',
      ));
      await tester.pumpAndSettle();
      expect(find.textContaining('Create an account'), findsNothing);
    });
  });
}
