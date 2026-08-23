import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/features/landing/landing_content.dart';

/// The landing page, on the screen side.
///
/// What a stranger may reach, and that an unpublished page stays
/// unpublished, is asserted in `supabase/tests/landing_page.sql` where
/// it belongs — those are policies and a SECURITY DEFINER function, and
/// a screen cannot weaken them.
///
/// What is asserted here is the thing the screen decides on its own:
/// that it survives whatever comes back. This page is the only route a
/// signed-out visitor has to the sign-in button, so a parser that throws
/// on an unexpected shape locks everybody out of their books.
void main() {
  group('an unwritten page', () {
    test('nothing at all still gives a page to draw', () {
      final c = parseLandingContent(null);
      expect(c.published, isFalse);
      expect(c.wordmark, 'iAkauntan');
      expect(c.signInLabel, 'Sign in');
      // The built-in copy, not a blank screen: somebody arriving before
      // anybody has written the site can still sign in.
      expect(c.heroHeadline, isNotEmpty);
    });

    test('a null page is unpublished, whatever else came with it', () {
      final c = parseLandingContent({
        'page': null,
        'sections': [
          {'title': 'Draft'},
        ],
        'app_links': [
          {'store_code': 'play_store', 'url': 'https://play.google.com/x'},
        ],
      });
      expect(c.published, isFalse);
      // And the draft does not leak in through the lists. The database
      // withholds them too; this is the second lock on the same door.
      expect(c.sections, isEmpty);
      expect(c.appLinks, isEmpty);
    });

    test('something that is not a map at all', () {
      expect(parseLandingContent('nonsense').published, isFalse);
      expect(parseLandingContent(42).published, isFalse);
      expect(parseLandingContent(const []).published, isFalse);
    });
  });

  group('a written page', () {
    LandingContent published(Map<String, dynamic> extra) => parseLandingContent({
          'page': {'wordmark': 'iAkauntan', ...extra},
          'sections': const [],
          'app_links': const [],
        });

    test('the fields it carries', () {
      final c = published({
        'tagline': 'Kira, bukan agak',
        'hero_headline': 'Perakaunan untuk perniagaan Malaysia',
        'logo_url': 'https://cdn.test/mark.png',
        'register_enabled': false,
      });
      expect(c.published, isTrue);
      expect(c.tagline, 'Kira, bukan agak');
      expect(c.heroHeadline, 'Perakaunan untuk perniagaan Malaysia');
      expect(c.logoUrl, 'https://cdn.test/mark.png');
      expect(c.registerEnabled, isFalse);
    });

    test('an empty string is as good as absent', () {
      // The console saves what the form holds, and a field somebody
      // cleared arrives as '' rather than as null. Drawn as absent, or
      // the page shows a heading with nothing under it.
      final c = published({'tagline': '   ', 'hero_headline': ''});
      expect(c.tagline, isNull);
      expect(c.heroHeadline, isNotEmpty);
    });

    test('a field of the wrong type does not take the page down', () {
      final c = published({'tagline': 42, 'register_enabled': 'yes'});
      expect(c.published, isTrue);
      expect(c.tagline, isNull);
      // Not 'yes': anything that is not a boolean leaves registration
      // as it was, which is on. Refusing to let anybody sign up because
      // a field arrived malformed is the worse failure.
      expect(c.registerEnabled, isTrue);
    });
  });

  group('sections', () {
    test('kept in the order they arrived', () {
      final c = parseLandingContent({
        'page': {'wordmark': 'x'},
        'sections': [
          {'title': 'One', 'body': 'First', 'icon': 'receipt'},
          {'title': 'Two', 'body': 'Second'},
        ],
      });
      expect(c.sections.map((s) => s.title), ['One', 'Two']);
      expect(c.sections.first.icon, 'receipt');
    });

    test('one without a title is dropped, and the rest survive', () {
      final c = parseLandingContent({
        'page': {'wordmark': 'x'},
        'sections': [
          {'body': 'No title'},
          {'title': '   '},
          {'title': 'Real'},
          'not a map',
        ],
      });
      expect(c.sections.map((s) => s.title), ['Real']);
    });
  });

  group('store buttons', () {
    test('a button with nowhere to go is dropped', () {
      // Worse than an absent one: the visitor taps it, nothing happens,
      // and they decide the product is broken.
      final c = parseLandingContent({
        'page': {'wordmark': 'x'},
        'app_links': [
          {'store_code': 'play_store', 'url': 'play.google.com/store'},
          {'store_code': 'app_store', 'url': 'https://apps.apple.com/my/app/x'},
          {'store_code': '', 'url': 'https://example.test'},
          {'url': 'https://example.test'},
        ],
      });
      expect(c.appLinks.map((l) => l.storeCode), ['app_store']);
    });

    test('a button with no label is labelled by its shop', () {
      final c = parseLandingContent({
        'page': {'wordmark': 'x'},
        'app_links': [
          {'store_code': 'appgallery', 'url': 'https://appgallery.test/x'},
        ],
      });
      expect(c.appLinks.single.label, 'appgallery');
    });
  });
}
