import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../tool/brand_chrome.dart';

/// What the browser is told before any Dart has run.
///
/// `web/index.html` is hand-written in this repository rather than
/// generated, because the branding markers live in it. That makes it a
/// file a line can quietly fall out of, and one line falling out of it
/// is the difference between a product that works on a phone and one
/// that does not.
void main() {
  final index = File('web/index.html').readAsStringSync();

  group('the viewport', () {
    // WITHOUT THIS TAG THE WHOLE APP IS A DESKTOP ON A PHONE. A mobile
    // browser given no viewport lays the page out at about 980 CSS
    // pixels and scales it, so Flutter is told the window is 980 wide
    // on a screen that is 390. Every `MediaQuery.sizeOf` check in the
    // product then reads a desktop and renders one, which is squeezed
    // and clipped. It was reported as an item list running one letter
    // per line; it was every screen.
    test('is declared at all', () {
      expect(index, contains('name="viewport"'));
    });

    test('and is the device width, not a made-up one', () {
      final tag = RegExp(r'<meta\s+name="viewport"[^>]*>', dotAll: true)
          .firstMatch(index)
          ?.group(0);
      expect(tag, isNotNull, reason: 'no viewport meta in web/index.html');
      expect(tag, contains('width=device-width'));
      expect(tag, contains('initial-scale=1'));
    });

    test('and the branding stamper leaves it alone', () {
      // The stamper rewrites this file on every build. It replaces
      // three marker comments and must touch nothing else.
      final stamped = stampIndexHtml(
        index,
        const Brand(name: 'Kira', title: 'Kira', description: 'Books.',
            colour: '#0F172A'),
      );
      expect(stamped, contains('width=device-width'));
    });
  });

  group('the markers the stamper needs', () {
    // A marker renamed or removed does not fail a build: it ships the
    // comment to a browser and the product goes out unbranded.
    for (final marker in const [
      '<!-- brand:description -->',
      '<!-- brand:theme-color -->',
      '<!-- brand:apple-title -->',
    ]) {
      test('$marker is still there', () {
        expect(index, contains(marker));
      });
    }
  });
}
