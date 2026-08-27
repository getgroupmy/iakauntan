import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import '../tool/brand_chrome.dart';

/// What the browser itself is told this product is called.
///
/// The tab, the tint on an Android address bar, the sentence a link
/// preview reads and the whole of what a PWA install shows. All of it
/// used to be a literal in `web/index.html` and `web/manifest.json`, so
/// every deployment of this software claimed to be iAkauntan.
///
/// The failures worth catching here are quiet ones: a manifest that
/// stops parsing loses the icons as well as the name, and a field left
/// unstamped ships a marker comment nobody sees rather than an error.
void main() {
  const html = '''
<head>
  <!-- brand:description -->
  <!-- brand:theme-color -->
  <!-- brand:apple-title -->
  <title>Loading…</title>
</head>''';

  const manifest = '''
{
    "name": "",
    "short_name": "",
    "start_url": ".",
    "description": "",
    "icons": [{"src": "icons/Icon-192.png"}]
}''';

  group('reading the payload', () {
    test('takes the brand, which is not gated on publication', () {
      final brand = Brand.fromPayload(const {
        'brand': {
          'wordmark': 'Kira Kira',
          'brand_colour': '#0f172a',
          'meta_description': 'Books for Malaysian business.',
        },
      });

      expect(brand.name, 'Kira Kira');
      expect(brand.title, 'Kira Kira');
      expect(brand.description, 'Books for Malaysian business.');
      // Normalised, because a manifest and a meta tag should not
      // disagree about the same colour's spelling.
      expect(brand.colour, '#0F172A');
    });

    test('and prefers a written page title over the wordmark', () {
      final brand = Brand.fromPayload(const {
        'brand': {'wordmark': 'Kira Kira', 'meta_title': 'Kira Kira — books'},
      });

      expect(brand.title, 'Kira Kira — books');
      // The short name stays the short one: an install tile has room
      // for a word, not a sentence.
      expect(brand.name, 'Kira Kira');
    });

    test('falls back to page for a payload written before brand existed', () {
      final brand = Brand.fromPayload(const {
        'page': {'wordmark': 'Kira Kira'},
      });
      expect(brand.name, 'Kira Kira');
    });

    test('treats a colour that is not a colour as unset', () {
      // A manifest carrying a malformed colour is one some browsers
      // reject wholesale, which costs the install prompt entirely — so
      // nothing is worth more here than something wrong.
      for (final v in const ['teal', '#GGG', '#0F172', '', '  ']) {
        expect(
          Brand.fromPayload({
            'brand': {'brand_colour': v},
          }).colour,
          isNull,
          reason: v,
        );
      }
    });

    test('and an empty payload is empty rather than a crash', () {
      expect(Brand.fromPayload(null).isEmpty, isTrue);
      expect(Brand.fromPayload('nonsense').isEmpty, isTrue);
      expect(Brand.fromPayload(const {'page': null}).isEmpty, isTrue);
    });
  });

  group('index.html', () {
    test('gets the colour, the description, the name and the title', () {
      final out = stampIndexHtml(
        html,
        const Brand(
          name: 'Kira Kira',
          title: 'Kira Kira — books',
          description: 'Books for Malaysian business.',
          colour: '#0F172A',
        ),
      );

      expect(out, contains('<meta name="theme-color" content="#0F172A">'));
      expect(
        out,
        contains('<meta name="description" '
            'content="Books for Malaysian business.">'),
      );
      expect(
        out,
        contains('<meta name="apple-mobile-web-app-title" '
            'content="Kira Kira">'),
      );
      expect(out, contains('<title>Kira Kira — books</title>'));
      expect(out, isNot(contains('Loading…')));
    });

    test('leaves a marker alone for a field nobody has set', () {
      // A comment renders as nothing, which is the right rendering of
      // "this platform has not said" — and much better than an empty
      // meta tag, which some crawlers read as an empty description.
      final out = stampIndexHtml(html, const Brand(name: 'Kira Kira'));

      expect(out, contains('<!-- brand:theme-color -->'));
      expect(out, contains('<!-- brand:description -->'));
      expect(out, isNot(contains('theme-color" content')));
    });

    test('and escapes a name with a quote in it', () {
      final out = stampIndexHtml(
        html,
        const Brand(name: 'Bob "The Books" Sdn Bhd'),
      );

      expect(out, contains('content="Bob &quot;The Books&quot; Sdn Bhd"'));
      // The attribute must not be closed early by the value itself.
      expect(out, isNot(contains('content="Bob "The')));
    });
  });

  group('manifest.json', () {
    Map<String, Object?> parse(String s) =>
        (jsonDecode(s) as Map).cast<String, Object?>();

    test('is filled in and still parses', () {
      final out = parse(stampManifest(
        manifest,
        const Brand(
          name: 'Kira Kira',
          title: 'Kira Kira — books',
          description: 'Books.',
          colour: '#0F172A',
        ),
      ));

      expect(out['name'], 'Kira Kira — books');
      expect(out['short_name'], 'Kira Kira');
      expect(out['description'], 'Books.');
      expect(out['theme_color'], '#0F172A');
      // The icons are the reason a broken manifest is expensive.
      expect(out['icons'], isA<List<Object?>>());
      expect(out['start_url'], '.');
    });

    test('survives a name that would break a string substitution', () {
      final out = parse(stampManifest(
        manifest,
        const Brand(name: 'Bob "The Books"', title: 'Bob "The Books"'),
      ));

      expect(out['short_name'], 'Bob "The Books"');
      expect(out['icons'], isA<List<Object?>>());
    });

    test('leaves a field nobody has set as it found it', () {
      final out = parse(stampManifest(manifest, const Brand(name: 'Kira')));

      expect(out['short_name'], 'Kira');
      expect(out.containsKey('theme_color'), isFalse);
    });

    test('and a manifest that does not parse is returned untouched', () {
      expect(stampManifest('{not json', const Brand(name: 'Kira')),
          '{not json');
    });
  });
}
