import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iakauntan/src/data/site_pages_repository.dart';
import 'package:iakauntan/src/features/admin/site_pages_admin.dart';
import 'package:iakauntan/src/features/landing/landing_content.dart';
import 'package:iakauntan/src/features/landing/landing_screen.dart';
import 'package:iakauntan/src/features/landing/site_page_screen.dart';

/// The five pages around the product.
///
/// What is worth asserting here is the fallback, in both directions:
/// a page nobody has written must still draw something a visitor can
/// read, and a page somebody *has* written must not be quietly ignored
/// in favour of the shipped words. Both failures look like a working
/// screen.
void main() {
  Widget wrap(Widget child, Map<String, SitePage> pages) => ProviderScope(
    overrides: [
      sitePagesProvider.overrideWith((ref) async => pages),
      landingContentProvider.overrideWith(
        (ref) async => LandingContent.fallback,
      ),
    ],
    child: MaterialApp(home: child),
  );

  group('a page a visitor reads', () {
    testWidgets('falls back to a heading when nobody has written one',
        (tester) async {
      await tester.pumpWidget(wrap(const SitePageScreen(slug: 'privacy'), {}));
      await tester.pumpAndSettle();

      expect(find.text('Privacy Policy'), findsOneWidget);
    });

    testWidgets('says so plainly rather than showing an empty page',
        (tester) async {
      await tester.pumpWidget(wrap(const SitePageScreen(slug: 'terms'), {}));
      await tester.pumpAndSettle();

      // Not an error and not a blank: the operator has not finished
      // setting up, and the visitor's next move is to ask.
      expect(find.textContaining('has not been written yet'), findsOneWidget);
    });

    testWidgets('and prefers what the operator wrote', (tester) async {
      await tester.pumpWidget(wrap(
        const SitePageScreen(slug: 'terms'),
        const {
          'terms': SitePage(
            slug: 'terms',
            title: 'Syarat Penggunaan',
            body: 'Satu. Dua. Tiga.',
            isPublished: true,
          ),
        },
      ));
      await tester.pumpAndSettle();

      expect(find.text('Syarat Penggunaan'), findsOneWidget);
      expect(find.text('Satu. Dua. Tiga.'), findsOneWidget);
      expect(find.text('Terms of Use'), findsNothing);
      expect(find.textContaining('has not been written yet'), findsNothing);
    });

    testWidgets('and offers the way back', (tester) async {
      await tester.pumpWidget(wrap(const SitePageScreen(slug: 'contact'), {}));
      await tester.pumpAndSettle();

      expect(find.textContaining('Back to'), findsOneWidget);
    });
  });

  group('the console form', () {
    // A published page is a decision on the three the footer links to,
    // and no decision at all on the two that always draw. A switch that
    // changes nothing is worse than an absent one.
    test('knows which pages have something to publish', () {
      for (final slug in ['terms', 'privacy', 'contact']) {
        expect(sitePageHint(slug), contains('once published'), reason: slug);
      }
      for (final slug in ['signin', 'signup']) {
        expect(
          sitePageHint(slug),
          contains('nothing to publish'),
          reason: slug,
        );
      }
    });

    test('names all five, and names them the same way twice', () {
      const slugs = ['signin', 'signup', 'terms', 'privacy', 'contact'];
      for (final slug in slugs) {
        // A label that fell through to the raw slug would put "privacy"
        // in the operator's menu, which is a bug that ships silently.
        expect(sitePageLabel(slug), isNot(slug), reason: slug);
        expect(sitePageHint(slug), isNotEmpty, reason: slug);
      }
      expect(slugs.map(sitePageLabel).toSet(), hasLength(5));
    });
  });

  group('a row from the database', () {
    test('reads a null heading as absent rather than as empty', () {
      final page = SitePage.fromRow(const {
        'slug': 'terms',
        'title': null,
        'body': null,
        'is_published': false,
      });
      expect(page.title, isNull);
      expect(page.body, isNull);
      expect(page.isPublished, isFalse);
    });

    test('and carries the published flag through', () {
      final page = SitePage.fromRow(const {
        'slug': 'privacy',
        'title': 'Dasar Privasi',
        'body': 'Apa yang berlaku kepada anda.',
        'is_published': true,
      });
      expect(page.slug, 'privacy');
      expect(page.title, 'Dasar Privasi');
      expect(page.isPublished, isTrue);
    });
  });

  group('the footer of the front page', () {
    Future<void> pumpFooter(
      WidgetTester tester, {
      required Set<String> pages,
      String? termsUrl,
      String? privacyUrl,
    }) async {
      tester.view.physicalSize = const Size(1280, 4000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => MediaQuery(
                data: MediaQuery.of(context).copyWith(disableAnimations: true),
                child: LandingPage(
                  content: LandingContent(
                    published: true,
                    termsUrl: termsUrl,
                    privacyUrl: privacyUrl,
                  ),
                  preview: true,
                  pages: pages,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('links to a page written here', (tester) async {
      await pumpFooter(tester, pages: {'terms', 'privacy', 'contact'});

      expect(find.text('Terms'), findsOneWidget);
      expect(find.text('Privacy'), findsOneWidget);
      expect(find.text('Contact us'), findsOneWidget);
    });

    testWidgets('and draws no link at all for one nobody has published',
        (tester) async {
      // The rule the footer has always had: a heading with nothing
      // behind it looks like a bigger company and behaves like a
      // broken one.
      await pumpFooter(tester, pages: const {});

      expect(find.text('Terms'), findsNothing);
      expect(find.text('Privacy'), findsNothing);
      expect(find.text('Contact us'), findsNothing);
    });

    testWidgets('but still uses the URL column when there is no page here',
        (tester) async {
      // A platform whose legal pages live on its own site keeps them.
      await pumpFooter(
        tester,
        pages: const {},
        termsUrl: 'https://example.test/terms',
        privacyUrl: 'https://example.test/privacy',
      );

      expect(find.text('Terms'), findsOneWidget);
      expect(find.text('Privacy'), findsOneWidget);
      // Contact has no column to fall back to, so it stays absent.
      expect(find.text('Contact us'), findsNothing);
    });
  });

  test('the shipped heading matches the console label for the three '
      'pages that have both', () {
    // Two names for the same page, in two files. They drift, and the
    // drift shows up as an operator looking for "Terms of Use" in a
    // console section called something else.
    for (final slug in ['terms', 'privacy', 'contact']) {
      expect(defaultSitePageTitle(slug), sitePageLabel(slug), reason: slug);
    }
  });
}
