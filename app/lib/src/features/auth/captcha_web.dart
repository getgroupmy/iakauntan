import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:ui_web' as ui_web;

import 'package:flutter/material.dart';
import 'package:web/web.dart' as web;

import 'captcha_controller.dart';

/// Cloudflare Turnstile, drawn into the page beside the form.
///
/// Turnstile is a browser widget: a script from `challenges.cloudflare
/// .com` renders into a div and calls back with a token. There is no
/// Flutter port of it and there cannot usefully be one, so this puts a
/// real `<div>` on the page with `HtmlElementView` and lets Cloudflare
/// draw into it — the same arrangement the favicon and the download
/// helper already use for things only a browser can do.
///
/// The token is what GoTrue wants. It lasts about five minutes, and
/// Turnstile calls the expiry callback when it goes stale; the parent
/// is told with a null so the form can ask again rather than sending
/// something the server will refuse.
@JS('turnstile')
external JSObject? get _turnstile;

@JS('turnstile.render')
external JSString? _render(JSAny container, JSObject options);

/// Throw away the token this widget is holding and challenge again.
///
/// Cloudflare's own way of saying it, and the only one: a token is
/// spent by the attempt that used it, and without this a form that
/// failed once has nothing valid left to send. See [CaptchaController].
@JS('turnstile.reset')
external void _resetWidget(JSString widgetId);

/// The script tag, added once per page.
///
/// `render=explicit` because the widget is created when a form asks for
/// it rather than at load: an automatic render would look for divs that
/// do not exist yet on a single-page app.
bool _scriptAdded = false;

/// Set when the browser refuses or fails to fetch the script.
///
/// A blocked script is not an error this app can catch: the Content-
/// Security-Policy refusal is a console message on somebody else's
/// machine, and `onerror` is the only hint the page gets. It shipped
/// blocked once — `script-src 'self'` — and the only symptom was a form
/// asking for a check that was not on the screen.
bool _scriptFailed = false;

void _ensureScript() {
  if (_scriptAdded) return;
  _scriptAdded = true;
  final script = web.document.createElement('script') as web.HTMLScriptElement
    ..src =
        'https://challenges.cloudflare.com/turnstile/v0/api.js'
        '?render=explicit'
    ..async = true
    ..defer = true;
  script.onerror = ((JSAny _) => _scriptFailed = true).toJS;
  web.document.head!.appendChild(script);
}

/// One view type per site key, registered once — and the div each view
/// made, kept by id.
///
/// Kept rather than looked up in the document: Flutter decides where a
/// platform view lands and renames the shadow host between versions, so
/// a querySelector for it is a thing that works until it does not. The
/// factory made the element; holding on to it is the only way to be
/// sure the right one is handed to Cloudflare.
final _registered = <String>{};
final _hosts = <int, web.HTMLDivElement>{};

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

  /// Called once when the widget will not be drawn at all.
  final VoidCallback onFailed;

  /// Asks for a fresh challenge when a form's attempt has spent the
  /// token it was holding.
  final CaptchaController? controller;

  @override
  State<TurnstileWidget> createState() => _TurnstileWidgetState();
}

class _TurnstileWidgetState extends State<TurnstileWidget> {
  late final String _viewType = 'turnstile-${widget.siteKey}';
  bool _gaveUp = false;

  /// What Cloudflare called the widget it drew, which is what has to be
  /// handed back to reset it. Null until it has drawn one.
  String? _widgetId;

  @override
  void initState() {
    super.initState();
    widget.controller?.addListener(_again);
    _ensureScript();
    if (_registered.add(_viewType)) {
      ui_web.platformViewRegistry.registerViewFactory(_viewType, (int id) {
        final host = web.document.createElement('div') as web.HTMLDivElement;
        _hosts[id] = host;
        return host;
      });
    }
  }

  /// How many 200ms turns to wait for the script before saying so.
  ///
  /// Ten seconds. Long enough for a slow connection, short enough that
  /// somebody staring at a gap gets an answer rather than a gap.
  static const _maxTries = 50;
  int _tries = 0;

  /// Ask Cloudflare to draw into the div once it is in the document.
  ///
  /// The script may still be loading when the form is built, so this
  /// retries rather than giving up at once: a captcha that fails to
  /// appear is a form nobody can submit.
  ///
  /// BOUNDED, and that is the point. It used to retry for ever, so a
  /// script the browser had refused produced an empty box that polled
  /// silently for the life of the screen while the form went on
  /// demanding a token from it. Giving up and saying so is worse for
  /// nobody: the check is not coming.
  void _renderInto(web.Element container) {
    if (_scriptFailed || _tries >= _maxTries) {
      if (!_gaveUp) {
        _gaveUp = true;
        widget.onFailed();
      }
      return;
    }
    if (_turnstile == null) {
      _tries += 1;
      Future<void>.delayed(const Duration(milliseconds: 200), () {
        if (mounted) _renderInto(container);
      });
      return;
    }
    if (container.hasChildNodes()) return;
    final options = JSObject()
      ..setProperty('sitekey'.toJS, widget.siteKey.toJS)
      ..setProperty(
        'callback'.toJS,
        ((JSString token) => widget.onToken(token.toDart)).toJS,
      )
      // Both of these mean "the token you have is no longer any good".
      // Telling the form so is what stops it sending one GoTrue will
      // refuse with nothing on screen to explain it.
      ..setProperty('expired-callback'.toJS, (() => widget.onToken(null)).toJS)
      ..setProperty('error-callback'.toJS, (() => widget.onToken(null)).toJS);
    _widgetId = _render(container as JSAny, options)?.toDart;
  }

  /// Run the check again, at a form's request.
  ///
  /// Silent when nothing has been drawn yet: there is no spent token to
  /// replace, and the form is already waiting for the first one.
  void _again() {
    final id = _widgetId;
    if (id == null || _gaveUp) return;
    // Told at once that the token it held is worthless, rather than
    // when Cloudflare gets round to the new one. A form that thinks it
    // still has a token between the reset and the callback would send
    // the spent one.
    widget.onToken(null);
    _resetWidget(id.toJS);
  }

  @override
  void dispose() {
    widget.controller?.removeListener(_again);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 70,
      child: HtmlElementView(
        viewType: _viewType,
        onPlatformViewCreated: (id) {
          final host = _hosts[id];
          if (host != null) _renderInto(host);
        },
      ),
    );
  }
}
