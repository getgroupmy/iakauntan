import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/core/safe_link.dart';

/// `Uri.base.origin` throws, and four screens called it unguarded.
///
/// The `Bad state: Origin is only applicable schemes http and https` is
/// not an edge case on this product: on Android, iOS, macOS and Windows
/// `Uri.base` is a `file:` URI, so it is every native run. The published
/// menus screen called it inside `build` and threw on every row.
///
/// A unit test cannot change `Uri.base`, which is exactly why this is
/// two tests rather than one. The first asserts the property that
/// matters at every call site -- that it does not throw and gives back
/// something linkable -- under the scheme THIS test process runs with,
/// which is `file:`, the native case. The second holds the rule itself
/// against every scheme, separately from the ambient one.
void main() {
  group('shareOrigin', () {
    test('does not throw under a file: base, which is every phone', () {
      // Uri.base here is the test working directory: file:///...
      expect(Uri.base.isScheme('file'), isTrue,
          reason: 'the point of this test is the non-http case');
      // The call that used to be `Uri.base.origin`.
      late final String origin;
      expect(() => origin = shareOrigin(), returnsNormally);
      expect(origin, startsWith('https://'));
    });

    test('and what it returns builds a link that would resolve', () {
      final url = '${shareOrigin()}/#/menu/abc123';
      final parsed = Uri.parse(url);
      expect(parsed.scheme, anyOf('http', 'https'));
      expect(parsed.host, isNotEmpty);
      expect(parsed.fragment, '/menu/abc123');
    });

    test('the fallback is the same address the database falls back to', () {
      // `app.portal_url` coalesces `platform_settings.site_url` to
      // this, from 0494. Two copies of one fact, so they are asserted
      // to agree rather than left to drift.
      expect(shareOrigin(), 'https://iakauntan.com');
    });
  });

  group('the rule it encodes', () {
    // Stated as a predicate over schemes, because the ambient Uri.base
    // cannot be moved inside a test and asserting only the ambient one
    // would leave the http branch unexercised.
    bool usable(String base) {
      final u = Uri.parse(base);
      return u.isScheme('http') || u.isScheme('https');
    }

    test('an http or https base is used as it stands', () {
      expect(usable('https://sinar.iakauntan.com/#/pos'), isTrue);
      expect(usable('http://localhost:8080/'), isTrue);
      // And its origin is the per-tenant answer, which is the whole
      // point of a custom workspace host.
      expect(Uri.parse('https://sinar.iakauntan.com/#/pos').origin,
          'https://sinar.iakauntan.com');
    });

    test('every other scheme is not, and asking for its origin throws', () {
      for (final base in [
        'file:///home/user/app/',
        'content://media/external/file/42',
        'about:blank',
      ]) {
        expect(usable(base), isFalse, reason: base);
        expect(() => Uri.parse(base).origin, throwsStateError, reason: base);
      }
    });
  });
}
