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

  void _build(bool dark) {
    _dark = dark;
    _web = WebViewController()
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
        // follow an unexpected navigation.
        onNavigationRequest: (r) => r.url.startsWith(captchaHost)
            ? NavigationDecision.navigate
            : NavigationDecision.prevent,
      ))
      ..loadRequest(captchaUri(widget.siteKey, dark: dark));
  }

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    if (_web == null || dark != _dark) _build(dark);

    if (_failed) return const SizedBox.shrink();
    return SizedBox(
      height: captchaHeight,
      child: WebViewWidget(controller: _web!),
    );
  }
}
