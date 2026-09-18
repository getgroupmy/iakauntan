import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'captcha_controller.dart';

/// The Turnstile challenge on a phone, in a webview.
///
/// Cloudflare publishes no native SDK — Turnstile is a browser widget —
/// so the only way iOS and Android can produce a token is to host the
/// real page and read the token back out of it. `web/captcha.html` is
/// the other half, and it is served from the web app's own domain
/// because a site key is scoped to a list of domains and the widget
/// refuses to render anywhere else. Loading an HTML string into the
/// webview instead would put the challenge on `about:blank`, where it
/// works only if the key is left unscoped — which is the protection
/// switched off.
///
/// This replaces `captcha_stub.dart` on mobile. Before it, the sign-in
/// form said the check could not be completed here and told people to
/// use the web app; with the dashboard switch ON that was not advice
/// but a lockout, because GoTrue requires a token from every platform
/// once the project is protected.

/// Where `captcha.html` is served from.
///
/// A `--dart-define` rather than a constant, so a deployment on another
/// domain does not need a code change — the same reason `PRODUCTION_URL`
/// is a repository variable in `ci.yml`. The default is this project's
/// own domain, which is where the web app and therefore the page is.
const captchaHost = String.fromEnvironment(
  'CAPTCHA_HOST',
  defaultValue: 'https://iakauntan.com',
);

/// The page to load, for a given key and theme.
///
/// Pulled out of the widget so it can be asserted without a webview:
/// getting the origin or the parameter name wrong produces a challenge
/// that silently never renders, which is the failure hardest to tell
/// from a slow network.
Uri captchaUri(String siteKey, {bool dark = false, String host = captchaHost}) =>
    Uri.parse('$host/captcha.html').replace(queryParameters: {
      'k': siteKey.trim(),
      if (dark) 'theme': 'dark',
    });

/// What the page sent back.
///
/// The page speaks one message shape and this reads it. A malformed
/// message is a failure rather than an exception: it arrives from a
/// webview, on a thread nothing above can catch, and a crash there
/// takes the sign-in screen with it.
({String kind, String value})? captchaMessage(String raw) {
  try {
    final m = jsonDecode(raw);
    if (m is! Map) return null;
    final kind = m['kind'];
    if (kind is! String || kind.isEmpty) return null;
    return (kind: kind, value: m['value']?.toString() ?? '');
  } catch (_) {
    return null;
  }
}

/// Whether the webview may follow this navigation.
///
/// The challenge page navigates nowhere, and a sign-in screen is the
/// last place to follow an unexpected navigation — so anything leaving
/// [host] is refused.
///
/// [isMainFrame] is the whole of this function, and leaving it out was
/// an iOS-ONLY LOCKOUT. Turnstile draws itself in an IFRAME served from
/// `challenges.cloudflare.com`, and the two platforms disagree about
/// whether the app is asked:
///
///   * `webview_flutter_android` consults the callback only for the
///     main frame, and says why in its own source — "the client is
///     only allowed to stop navigations that target the main frame
///     because overridden URLs are passed to `loadUrl` and `loadUrl`
///     cannot load a subframe". A subframe never reaches us, so the
///     iframe loaded and Android was fine.
///   * `webview_flutter_wkwebview` calls it from
///     `decidePolicyForNavigationAction` for EVERY navigation action
///     and passes `isMainFrame` through rather than filtering on it.
///
/// So on iPhone the guard cancelled Turnstile's own iframe, the widget
/// never rendered, and the form printed "the security check could not
/// load" — correctly, about a page nothing was wrong with.
///
/// A subframe is not left unguarded by this: the challenge page's
/// Content-Security-Policy decides what it may embed, which is where
/// that belongs and what `scripts/check_csp_allows.py` already asserts.
bool captchaMayNavigate(
  String url, {
  required bool isMainFrame,
  String host = captchaHost,
}) =>
    !isMainFrame || url.startsWith(host);

/// How tall to make the webview.
///
/// Turnstile's widget is 300x65 at its default size, and the page adds
/// nothing around it. Fixed rather than measured: a webview that sizes
/// itself needs a round trip to report its height, and the form would
/// jump once the challenge appeared.
const captchaHeight = 78.0;

class TurnstileWidget extends StatefulWidget {
  const TurnstileWidget({
    super.key,
    required this.siteKey,
    required this.onToken,
    required this.onFailed,
    this.controller,
  });

  final String siteKey;
  final ValueChanged<String?> onToken;

  /// Called once when the challenge will not be drawn at all.
  final VoidCallback onFailed;

  /// Asks for a fresh challenge when a form's attempt has spent the
  /// token it was holding. See [CaptchaController]: a Turnstile token
  /// is single use, and a form that re-sends a spent one is refused
  /// for the wrong reason.
  final CaptchaController? controller;

  @override
  State<TurnstileWidget> createState() => _TurnstileWidgetState();
}

class _TurnstileWidgetState extends State<TurnstileWidget> {
  WebViewController? _web;
  bool _failed = false;
  bool _dark = false;

  @override
  void initState() {
    super.initState();
    widget.controller?.addListener(_again);
  }

  @override
  void didUpdateWidget(TurnstileWidget old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      old.controller?.removeListener(_again);
      widget.controller?.addListener(_again);
    }
  }

  @override
  void dispose() {
    widget.controller?.removeListener(_again);
    super.dispose();
  }

  /// A fresh challenge, by reloading the page.
  ///
  /// Reload rather than `turnstile.reset()` over a JavaScript bridge:
  /// one round trip either way, and a reload cannot leave the widget
  /// in a half-reset state the app cannot see.
  void _again() {
    if (!mounted) return;
    widget.onToken(null);
    _web?.loadRequest(captchaUri(widget.siteKey, dark: _dark));
  }

  void _onMessage(String raw) {
    final m = captchaMessage(raw);
    if (m == null || !mounted) return;
    switch (m.kind) {
      case 'token':
        if (m.value.isNotEmpty) widget.onToken(m.value);
      case 'expired':
        // Told, rather than left holding a token GoTrue will refuse
        // with nothing on screen to explain it.
        widget.onToken(null);
      case 'failed':
        if (_failed) return;
        setState(() => _failed = true);
        widget.onFailed();
    }
  }

  /// Build the webview, or report that there is none.
  ///
  /// `WebViewController()` THROWS where no platform implementation is
  /// registered — a widget test, a platform the plugin does not cover,
  /// a build where it failed to link. Uncaught, that takes the whole
  /// sign-in screen down with a red error rather than failing the one
  /// field that cannot draw.
  ///
  /// So it is caught and reported as the failure it is: the form shows
  /// [captchaBroken] and refuses, which is what it already does for a
  /// challenge blocked by a network. A sign-in screen that cannot draw
  /// a captcha is a screen that cannot be submitted; it is not a screen
  /// that should crash.
  void _build(bool dark) {
    _dark = dark;
    try {
      _web = _controller(dark);
    } on Object {
      _web = null;
      // Deferred to after the frame. Calling it straight from here
      // does NOT throw — measured, not assumed: `_build` runs during
      // this element's own first build, where setState only marks it
      // dirty again. So a mutant that swaps the two survives, and it
      // is kept anyway: it works because of where `_build` happens to
      // be called from, and "setState during build is fine here" stops
      // being true the moment that moves.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _onMessage('{"kind":"failed","value":"no webview"}');
      });
    }
  }

  WebViewController _controller(bool dark) {
    return WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      // Transparent so the challenge sits on the form's own colour
      // rather than in a white rectangle on a dark theme.
      ..setBackgroundColor(const Color(0x00000000))
      ..addJavaScriptChannel('Captcha', onMessageReceived: (m) {
        _onMessage(m.message);
      })
      ..setNavigationDelegate(NavigationDelegate(
        // A page that cannot be fetched at all never runs the script
        // that would report its own failure, so the webview's error is
        // the only signal there is.
        onWebResourceError: (e) {
          if (e.isForMainFrame ?? true) _onMessage('{"kind":"failed"}');
        },
        // The challenge navigates nowhere. Anything trying to is not
        // the challenge, and a sign-in screen is the last place to
        // follow an unexpected navigation — but see
        // [captchaMayNavigate] for why the frame has to be asked
        // about, and why leaving it out shut every iPhone out of
        // signing in while Android worked.
        onNavigationRequest: (r) =>
            captchaMayNavigate(r.url, isMainFrame: r.isMainFrame)
                ? NavigationDecision.navigate
                : NavigationDecision.prevent,
      ))
      ..loadRequest(captchaUri(widget.siteKey, dark: dark));
  }

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    if (!_failed && (_web == null || dark != _dark)) _build(dark);

    if (_failed || _web == null) return const SizedBox.shrink();
    return SizedBox(
      height: captchaHeight,
      child: WebViewWidget(controller: _web!),
    );
  }
}
