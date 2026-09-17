import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iakauntan/src/core/page_waiting.dart';
import 'package:iakauntan/src/data/site_pages_repository.dart';
import 'package:iakauntan/src/features/landing/landing_content.dart';
import 'package:iakauntan/src/features/landing/landing_screen.dart';
import 'package:iakauntan/src/features/landing/site_page_screen.dart';
import 'package:iakauntan/src/features/landing/unknown_workspace_screen.dart';
import 'package:iakauntan/src/features/shell/app_shell.dart';

/// No page draws the product we shipped on the way to the one the
/// operator wrote.
///
/// Every public page had the same shape: `operatorsVersion ?? oursIs`,
/// evaluated while the operator's version was still in flight. So the
/// front page opened with our poster, the sign-in form with our labels,
/// a policy page with "there is nothing here yet", and each of them was
/// replaced half a second later. Somebody opening their own company's
/// front door saw somebody else's product first, on every load.
///
/// The fallbacks themselves are unchanged and still right: a payload
/// that is never coming means draw what we shipped with. It is only the
/// waiting that had no honest rendering.
void main() {
  setUp(() {
    final view = TestWidgetsFlutterBinding.ensureInitialized()
        .platformDispatcher
        .views
        .first;
    view.physicalSize = const Size(1400, 2400);
    view.devicePixelRatio = 1.0;
  });

  tearDown(() {
    final view = TestWidgetsFlutterBinding.ensureInitialized()
        .platformDispatcher
        .views
        .first;
    view.resetPhysicalSize();
    view.resetDevicePixelRatio();
  });

  /// A page pumped with nothing answered yet.
  Widget waiting(Widget page, {Completer<LandingContent>? landing}) =>
      ProviderScope(
        overrides: [
          landingContentProvider.overrideWith(
            (ref) => (landing ?? Completer<LandingContent>()).future,
          ),
          sitePagesProvider.overrideWith(
            (ref) => Completer<Map<String, SitePage>>().future,
          ),
        ],
        child: MaterialApp(home: page),
      );

  group('a page that is loading looks like a page that is loading', () {
    testWidgets('the front page', (tester) async {
      await tester.pumpWidget(waiting(const LandingScreen()));
      await tester.pump();

      expect(find.byType(PageWaiting), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      // The shipped headline is what `LandingContent.fallback` draws,
      // and it used to draw it here.
      expect(find.byType(LandingPage), findsNothing);
    });

    testWidgets('a policy page', (tester) async {
      await tester.pumpWidget(waiting(const SitePageScreen(slug: 'terms')));
      await tester.pump();

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      // "Nothing here yet" is the truth about a page nobody has
      // written, and a lie about one that has not arrived.
      expect(find.textContaining('nothing here yet'), findsNothing);
    });

    testWidgets('the page a name nobody holds lands on', (tester) async {
      await tester.pumpWidget(
        waiting(const UnknownWorkspaceScreen(host: 'nobody.iakauntan.com')),
      );
      await tester.pump();

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(
        find.text(LandingContent.defaultUnknownTitle),
        findsNothing,
      );
    });
  });

  testWidgets('and the operator\'s words are the only ones ever drawn',
      (tester) async {
    final landing = Completer<LandingContent>();
    await tester.pumpWidget(
      waiting(
        const UnknownWorkspaceScreen(host: 'nobody.iakauntan.com'),
        landing: landing,
      ),
    );
    await tester.pump();

    landing.complete(const LandingContent(
      published: true,
      unknownTitle: 'No such shop',
    ));
    await tester.pumpAndSettle();

    expect(find.text('No such shop'), findsOneWidget);
    expect(find.text(LandingContent.defaultUnknownTitle), findsNothing);
  });

  group('the name in the nav, which is not a page', () {
    // The shell cannot draw the circle: holding somebody's books behind
    // a spinner waiting on the landing payload would be a worse trade
    // than the flicker it fixes. So the word waits on its own — the
    // space where it goes stays empty for one round trip, and the name
    // arrives once instead of arriving wrong and being corrected.
    testWidgets('is nothing at all until the brand has landed',
        (tester) async {
      final landing = Completer<LandingContent>();
      String? seen;

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            landingContentProvider.overrideWith((ref) => landing.future),
          ],
          child: MaterialApp(
            home: Consumer(
              builder: (context, ref, _) {
                seen = platformWordmark(ref);
                return const SizedBox.shrink();
              },
            ),
          ),
        ),
      );
      await tester.pump();

      expect(seen, isNull);

      landing.complete(const LandingContent(
        published: true,
        wordmark: 'Kira',
      ));
      await tester.pumpAndSettle();

      expect(seen, 'Kira');
    });

    testWidgets('and is what we ship under when it is never coming',
        (tester) async {
      String? seen;

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            landingContentProvider.overrideWith(
              (ref) => Future<LandingContent>.error('no'),
            ),
          ],
          child: MaterialApp(
            home: Consumer(
              builder: (context, ref, _) {
                seen = platformWordmark(ref);
                return const SizedBox.shrink();
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(seen, 'iAkauntan');
    });
  });

  group('what counts as an answer', () {
    test('a value does', () {
      expect(settled(const AsyncData<int>(1)), isTrue);
    });

    test('and so does a failure, because the fallback is the answer', () {
      // A payload that is never coming means draw what we shipped with.
      // Treating an error as "still waiting" would spin forever on a
      // page somebody is trying to read.
      expect(settled(AsyncError<int>('no', StackTrace.empty)), isTrue);
    });

    test('waiting does not', () {
      expect(settled(const AsyncLoading<int>()), isFalse);
      expect(allSettled([const AsyncData<int>(1), const AsyncLoading<int>()]),
          isFalse);
      expect(allSettled([const AsyncData<int>(1), const AsyncData<int>(2)]),
          isTrue);
    });
  });
}
