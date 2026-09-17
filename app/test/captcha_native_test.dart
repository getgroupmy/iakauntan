@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:iakauntan/src/features/auth/captcha_native.dart';

/// The webview cannot be driven in a unit test, so what is asserted is
/// the contract either side of it: the URL the challenge is loaded
/// from, and the messages the page sends back.
///
/// Both are the failures that are hardest to see. A wrong origin or a
/// renamed query parameter produces a challenge that never renders,
/// which looks exactly like a slow network; a malformed message
/// arrives on a webview thread where an exception takes the sign-in
/// screen with it.
void main() {
  group('the page the challenge is loaded from', () {
    test('is on the configured host, not about:blank', () {
      // The whole reason this is a hosted page. A Turnstile site key is
      // scoped to a list of domains and the widget refuses to render
      // anywhere else, so an HTML string in a webview only works with
      // an unscoped key — which is the protection switched off.
      final u = captchaUri('abc', host: 'https://example.test');
      expect(u.scheme, 'https');
      expect(u.host, 'example.test');
      expect(u.path, '/captcha.html');
    });

    test('carries the site key as k', () {
      expect(captchaUri('abc').queryParameters['k'], 'abc');
    });

    test('trims the key, because the console stores what was pasted', () {
      expect(captchaUri('  abc \n').queryParameters['k'], 'abc');
    });

    test('asks for the dark widget only when dark', () {
      expect(captchaUri('abc', dark: true).queryParameters['theme'], 'dark');
      expect(
        captchaUri('abc').queryParameters.containsKey('theme'),
        isFalse,
        reason: 'no theme parameter should mean the light default',
      );
    });

    test('defaults to this project own domain', () {
      // A --dart-define overrides it; the default is where the web app
      // and therefore the page is.
      expect(captchaHost, startsWith('https://'));
      expect(captchaUri('abc').host, Uri.parse(captchaHost).host);
    });
  });

  group('what the page sends back', () {
    test('a token', () {
      final m = captchaMessage('{"kind":"token","value":"tok_123"}');
      expect(m?.kind, 'token');
      expect(m?.value, 'tok_123');
    });

    test('an expiry, which carries no value', () {
      final m = captchaMessage('{"kind":"expired","value":""}');
      expect(m?.kind, 'expired');
      expect(m?.value, '');
    });

    test('a failure', () {
      expect(captchaMessage('{"kind":"failed","value":"script blocked"}')?.kind,
          'failed');
    });

    test('a missing value reads as empty rather than throwing', () {
      expect(captchaMessage('{"kind":"expired"}')?.value, '');
    });
  });

  group('what it refuses, rather than throwing on a webview thread', () {
    test('malformed JSON', () {
      expect(captchaMessage('not json'), isNull);
    });

    // These two hold whether or not the explicit guards are there: for
    // anything that is not a Map, `m['kind']` throws, and a kind that
    // is not a String throws on the way into the record's String
    // field. The catch turns both into null either way, so a mutant
    // that deletes `is! Map` or the `is! String` half survives.
    //
    // The guards stay regardless. Reading them says what shape is
    // expected; the alternative says it by throwing, in a language
    // where the reader has to know that assigning an int to a String
    // field of a record is what stops it. Equivalent to a machine is
    // not equivalent to a person.
    test('JSON that is not an object', () {
      expect(captchaMessage('["token"]'), isNull);
      expect(captchaMessage('"token"'), isNull);
    });

    test('an object with no kind', () {
      expect(captchaMessage('{"value":"tok"}'), isNull);
    });

    test('a kind that is not a string', () {
      expect(captchaMessage('{"kind":1,"value":"tok"}'), isNull);
    });

    test('an empty kind', () {
      expect(captchaMessage('{"kind":"","value":"tok"}'), isNull);
    });

    test('an empty message', () {
      expect(captchaMessage(''), isNull);
    });
  });

  group('the hosted page itself', () {
    // The page is the other half of this contract and ships separately,
    // in web/. If the two drift the challenge silently never reports a
    // token, so the agreement is asserted rather than remembered.
    late final String html = File('web/captcha.html').readAsStringSync();
    // The logic lives in a FILE, not an inline block: the deployed CSP
    // is `script-src 'self' ... challenges.cloudflare.com` and refuses
    // inline script, silently, in the browser. On a sign-in screen
    // that looks like a challenge that never loads.
    late final String js = File('web/captcha.js').readAsStringSync();

    test('both halves exist where the deploy will publish them', () {
      expect(html, isNotEmpty);
      expect(js, isNotEmpty);
    });

    test('the page loads the script rather than inlining it', () {
      expect(html, contains('src="captcha.js"'));
      expect(
        html.contains('<script>'),
        isFalse,
        reason: 'an inline block is refused by the CSP at runtime',
      );
    });

    test('reads the same query parameter this file writes', () {
      expect(js, contains("get('k')"));
    });

    test('posts on the channel name the widget installs', () {
      expect(js, contains('window.Captcha'));
      expect(js, contains('postMessage'));
    });

    test('sends every kind the parser understands', () {
      for (final kind in ['token', 'expired', 'failed']) {
        expect(
          js,
          contains("send('$kind'"),
          reason: 'the page never sends "$kind", so the widget cannot act on it',
        );
      }
    });

    test('reports a blocked script rather than waiting forever', () {
      // If the Turnstile script cannot be fetched, nothing inside it
      // ever runs — so the failure has to come from the tag's onerror
      // or the app sits on a blank box indefinitely.
      expect(js, contains('onerror'));
    });

    test('loads Turnstile from Cloudflare and nothing else', () {
      expect(js, contains('challenges.cloudflare.com/turnstile'));
      final scripts = RegExp(r'\.src\s*=').allMatches(js);
      expect(
        scripts.length,
        1,
        reason: 'a sign-in screen should fetch one script, not several',
      );
    });
  });
}
