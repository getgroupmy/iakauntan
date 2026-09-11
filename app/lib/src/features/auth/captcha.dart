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

/// The widget itself, or nothing at all when no key is configured.
///
/// [onToken] is called with the token when the challenge passes, and
/// with null when it expires — Turnstile tokens last five minutes, and
/// a form holding an expired one would be refused by GoTrue with
/// nothing on the screen to explain it.
class CaptchaField extends StatelessWidget {
  const CaptchaField({
    super.key,
    required this.siteKey,
    required this.onToken,
  });

  final String? siteKey;
  final ValueChanged<String?> onToken;

  @override
  Widget build(BuildContext context) {
    if (!captchaOn(siteKey)) return const SizedBox.shrink();
    if (!captchaAvailable) {
      return Padding(
        padding: const EdgeInsets.only(top: 12),
        child: Text(
          captchaUnavailable,
          style: Theme.of(context).textTheme.bodySmall,
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: TurnstileWidget(siteKey: siteKey!.trim(), onToken: onToken),
    );
  }
}
