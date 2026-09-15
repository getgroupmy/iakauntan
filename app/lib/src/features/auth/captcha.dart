/// The check that asks whether a human is typing.
///
/// Cloudflare Turnstile, which Supabase Auth verifies for us: the
/// SECRET lives in the dashboard under Attack Protection, and all the
/// app has to do is draw the widget and hand GoTrue the token it
/// produces, as `captchaToken:` on sign-up, sign-in, the password reset
/// and the confirmation resend.
///
/// The SITE key is public by design — it identifies the widget to the
/// browser and proves nothing on its own — so it rides with the rest of
/// the sign-in page's appearance on `landing_page` (`0556`), where the
/// console can change it without a release.
///
/// EMPTY MEANS OFF. With no site key the field draws nothing and the
/// token is null, which is what every form did before this existed. So
/// the order to switch it on is: paste the key, watch a form draw the
/// widget, then turn the protection on in the dashboard — the other way
/// round refuses every sign-in on the project, including yours.
/// Whether a captcha is being asked for at all.
/// Whether this build can draw one.
///
/// The web can. Android and iOS cannot yet: Turnstile has no native
/// SDK and needs a webview, which this app does not carry. Said out
/// loud rather than left as a silent false, because the dashboard
/// switch protects the whole PROJECT — turning it on while a platform
/// cannot produce a token locks that platform out of signing in.
/// What the form says when it cannot draw one but one is expected.
/// What it says when somebody has not passed it yet.
/// The widget itself, or nothing at all when no key is configured.
///
/// [onToken] is called with the token when the challenge passes, and
/// with null when it expires — Turnstile tokens last five minutes, and
/// a form holding an expired one would be refused by GoTrue with
/// nothing on the screen to explain it.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'captcha_controller.dart';
export 'captcha_controller.dart' show CaptchaController;
import 'captcha_stub.dart' if (dart.library.js_interop) 'captcha_web.dart';

/// Whether a captcha is being asked for at all.
bool captchaOn(String? siteKey) => (siteKey ?? '').trim().isNotEmpty;

/// Whether this build can draw one.
///
/// The web can. Android and iOS cannot yet: Turnstile has no native
/// SDK and needs a webview, which this app does not carry. Said out
/// loud rather than left as a silent false, because the dashboard
/// switch protects the whole PROJECT — turning it on while a platform
/// cannot produce a token locks that platform out of signing in.
bool get captchaAvailable => kIsWeb;

/// What the form says when it cannot draw one but one is expected.
const captchaUnavailable =
    'This app cannot complete the security check on this device. Use '
    'the web app to sign in.';

/// What it says when somebody has not passed it yet.
const captchaNotDone = 'Complete the security check first';

/// What it says when the check could not be drawn at all.
///
/// A different sentence from [captchaNotDone] on purpose. "Complete the
/// security check first" is impossible to act on when there is no check
/// on the screen to complete, and that is exactly the state a blocked
/// script leaves the form in — it shipped that way once. This one names
/// the real problem and says who can fix it, because the person reading
/// it cannot.
const captchaBroken =
    'The security check could not load, so signing in is not possible '
    'from here. It is blocked by this site rather than by you — please '
    'tell whoever runs it.';

/// The widget itself, or nothing at all when no key is configured.
///
/// [onToken] is called with the token when the challenge passes, and
/// with null when it expires — Turnstile tokens last five minutes, and
/// a form holding an expired one would be refused by GoTrue with
/// nothing on the screen to explain it.
class CaptchaField extends StatefulWidget {
  const CaptchaField({
    super.key,
    required this.siteKey,
    required this.onToken,
    this.onFailed,
    this.controller,
  });

  final String? siteKey;
  final ValueChanged<String?> onToken;

  /// Ask the check to run again after a failed attempt. See
  /// [CaptchaController]: the token the attempt spent is no longer any
  /// good, and a form that re-sends it is refused for the wrong
  /// reason.
  final CaptchaController? controller;

  /// Told once when the check will not be drawn at all, so the form can
  /// refuse with [captchaBroken] instead of asking for something that
  /// is not there.
  final VoidCallback? onFailed;

  @override
  State<CaptchaField> createState() => _CaptchaFieldState();
}

class _CaptchaFieldState extends State<CaptchaField> {
  bool _failed = false;

  Widget _note(String text) => Padding(
    padding: const EdgeInsets.only(top: 12),
    child: Text(text, style: Theme.of(context).textTheme.bodySmall),
  );

  @override
  Widget build(BuildContext context) {
    if (!captchaOn(widget.siteKey)) return const SizedBox.shrink();
    if (!captchaAvailable) return _note(captchaUnavailable);
    if (_failed) return _note(captchaBroken);
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: TurnstileWidget(
        siteKey: widget.siteKey!.trim(),
        onToken: widget.onToken,
        controller: widget.controller,
        onFailed: () {
          if (!mounted || _failed) return;
          setState(() => _failed = true);
          widget.onFailed?.call();
        },
      ),
    );
  }
}
