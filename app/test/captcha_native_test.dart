@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter/material.dart';
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

  group('when there is no webview to draw in', () {
    // A unit test registers no webview platform, so `WebViewController()`
    // throws here exactly as it would in a build where the plugin
    // failed to link. That makes this the one part of the widget a
    // test can actually exercise — and the part where getting it wrong
    // takes the whole sign-in screen down rather than one field.
    testWidgets('it reports a failure instead of crashing', (tester) async {
      var failed = 0;
      String? token = 'stale';

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: TurnstileWidget(
            siteKey: 'abc',
            onToken: (t) => token = t,
            onFailed: () => failed++,
          ),
        ),
      ));
      await tester.pump();

      expect(
        tester.takeException(),
        isNull,
        reason: 'a missing webview must not take the screen down',
      );
      expect(failed, 1, reason: 'the form has to be told it cannot draw');
      expect(
        token,
        'stale',
        reason: 'a widget that cannot draw must not emit a token, and '
            'must not clear one the form already holds on its behalf',
      );
    });

    testWidgets('and says it once, not on every rebuild', (tester) async {
      var failed = 0;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: TurnstileWidget(
            siteKey: 'abc',
            onToken: (_) {},
            onFailed: () => failed++,
          ),
        ),
      ));
      await tester.pump();
      await tester.pump();
      await tester.pump();

      // A form that is told repeatedly would setState per frame.
      expect(failed, 1);

      // Note for a future sweep: this holds with the `!_failed` guard
      // in build() removed as well, because _onMessage's own `if
      // (_failed) return` already stops the second report. The guard
      // stops the widget CONSTRUCTING a webview on every rebuild after
      // it has given up, which costs something and shows up nowhere a
      // test can see. Both mutants are equivalent on behaviour and the
      // guards are kept for what they cost rather than what they
      // assert.
    });
  });

  /// The guard that shut every iPhone out.
  ///
  /// Turnstile draws itself in an iframe from
  /// `challenges.cloudflare.com`. The two webview plugins disagree
  /// about whether the app is consulted for a subframe:
  /// `webview_flutter_android` filters to the main frame and says so
  /// in its own source; `webview_flutter_wkwebview` calls the callback
  /// from `decidePolicyForNavigationAction` for EVERY navigation
  /// action and passes `isMainFrame` through rather than acting on it.
  ///
  /// So a guard written as `url.startsWith(host)` is correct on
  /// Android and cancels the challenge on iOS -- and the form then
  /// says the check could not load, about a page nothing is wrong
  /// with. It cannot be caught by running the app on one platform, and
  /// there is no browser test in CI, so it is pinned here.
  group('what the webview may follow', () {
    test('the challenge page itself', () {
      expect(
        captchaMayNavigate('https://iakauntan.com/captcha.html?k=x',
            isMainFrame: true),
        isTrue,
      );
    });

    test('and nothing else in the main frame', () {
      // The reason the guard exists: a sign-in screen is the last place
      // to follow a navigation somebody else chose.
      expect(
        captchaMayNavigate('https://example.test/phish', isMainFrame: true),
        isFalse,
      );
    });

    test('but a subframe is allowed wherever it points', () {
      // THE iOS BUG, in one assertion. Cloudflare serves the widget
      // from its own domain, and refusing this is refusing the
      // challenge.
      expect(
        captchaMayNavigate(
          'https://challenges.cloudflare.com/cdn-cgi/challenge-platform/x',
          isMainFrame: false,
        ),
        isTrue,
      );
    });

    test('including one that is nowhere near the host', () {
      // Not left to the CSP by accident -- deliberately. The page's own
      // `frame-src` decides what it may embed, which is where that
      // belongs and what `check_csp_allows.py` asserts. A second copy
      // of the rule here would be a second place for it to drift.
      expect(
        captchaMayNavigate('https://anywhere.test/x', isMainFrame: false),
        isTrue,
      );
    });

    test('and the host is the one the widget was configured with', () {
      expect(
        captchaMayNavigate('https://books.example/captcha.html',
            isMainFrame: true, host: 'https://books.example'),
        isTrue,
      );
      expect(
        captchaMayNavigate('https://iakauntan.com/captcha.html',
            isMainFrame: true, host: 'https://books.example'),
        isFalse,
      );
    });
  });

  /// Which webview errors mean the challenge will not appear.
  ///
  /// The iOS plugin reports every navigation error through
  /// `didFailProvisionalNavigation` with `isForMainFrame` HARDCODED to
  /// true, so the frame alone cannot tell a real failure from a
  /// cancelled subframe. And a cancellation is raised routinely: a new
  /// `loadRequest` supersedes one in flight, which is what
  /// `CaptchaController` does every time a form spends its token.
  /// Treating that as a failure locks the sign-in form for good.
  group('which errors mean no challenge', () {
    test('a page that cannot be fetched at all does', () {
      expect(
        captchaLoadFailed(errorCode: -1009, isForMainFrame: true),
        isTrue,
      );
    });

    test('but a cancelled navigation does not', () {
      expect(
        captchaLoadFailed(errorCode: captchaCancelled, isForMainFrame: true),
        isFalse,
      );
    });

    test('and -999 is the code, not a stand-in for any negative number', () {
      // Android's WebViewClient codes run -1 to -16, so naming -999 is
      // safe. An implementation that treated every negative code as a
      // cancellation would swallow all of them.
      expect(captchaCancelled, -999);
      for (final android in [-1, -2, -6, -8, -16]) {
        expect(
          captchaLoadFailed(errorCode: android, isForMainFrame: true),
          isTrue,
          reason: 'Android error $android is a real failure',
        );
      }
    });

    test('a subframe failure is not the challenge failing', () {
      expect(
        captchaLoadFailed(errorCode: -1009, isForMainFrame: false),
        isFalse,
      );
    });

    test('and an unknown frame is treated as the main one', () {
      // Null means the platform did not say. Refusing the form is the
      // safe direction: submitting without a token is refused by GoTrue
      // with nothing on screen to explain it.
      expect(captchaLoadFailed(errorCode: -1009), isTrue);
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
