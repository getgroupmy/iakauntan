import 'package:flutter/foundation.dart';

/// A handle for asking the security check to run again.
///
/// A Turnstile token is SINGLE USE and lasts about five minutes.
/// GoTrue spends it on the attempt whether the attempt succeeds or
/// not — so the token that went with a wrong password is gone, and
/// sending the same one again is answered
///
///     captcha protection: request disallowed
///
/// which reads on screen as the security check failing rather than as
/// the password being wrong. Somebody who mistypes their password once
/// then cannot get in at all, and nothing on the page says why.
///
/// So every form that can fail and be tried again holds one of these
/// and calls [reset] on the way out of the failure: a fresh challenge
/// on screen, a fresh token in the form.
///
/// In its own file because both `captcha_web.dart` and
/// `captcha_stub.dart` need it and `captcha.dart` imports whichever of
/// them applies — putting it there would be an import cycle.
///
/// A [ChangeNotifier] rather than a `GlobalKey` into the widget's
/// state: the caller needs to say "again", not to reach inside.
class CaptchaController extends ChangeNotifier {
  /// Throw the spent token away and run the check again.
  void reset() => notifyListeners();
}
