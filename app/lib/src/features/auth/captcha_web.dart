import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:ui_web' as ui_web;

import 'package:flutter/material.dart';
import 'package:web/web.dart' as web;

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

/// The script tag, added once per page.
///
/// `render=explicit` because the widget is created when a form asks for
/// it rather than at load: an automatic render would look for divs that
/// do not exist yet on a single-page app.
bool _scriptAdded = false;

void _ensureScript() {
  if (_scriptAdded) return;
  _scriptAdded = true;
  final script = web.document.createElement('script') as web.HTMLScriptElement
    ..src = 'https://challenges.cloudflare.com/turnstile/v0/api.js'
        '?render=explicit'
    ..async = true
    ..defer = true;
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
  });

  final String siteKey;
  final ValueChanged<String?> onToken;

  @override
  State<TurnstileWidget> createState() => _TurnstileWidgetState();
}

class _TurnstileWidgetState extends State<TurnstileWidget> {
  late final String _viewType = 'turnstile-${widget.siteKey}';

  @override
  void initState() {
    super.initState();
    _ensureScript();
    if (_registered.add(_viewType)) {
      ui_web.platformViewRegistry.registerViewFactory(
        _viewType,
        (int id) {
          final host =
              web.document.createElement('div') as web.HTMLDivElement;
          _hosts[id] = host;
          return host;
        },
      );
    }
  }

  /// Ask Cloudflare to draw into the div once it is in the document.
  ///
  /// The script may still be loading when the form is built, so this
  /// retries on a frame rather than giving up: a captcha that fails to
  /// appear is a form nobody can submit.
  void _renderInto(web.Element container) {
    if (_turnstile == null) {
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
      ..setProperty(
        'expired-callback'.toJS,
        (() => widget.onToken(null)).toJS,
      )
      ..setProperty(
        'error-callback'.toJS,
        (() => widget.onToken(null)).toJS,
      );
    _render(container as JSAny, options);
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
