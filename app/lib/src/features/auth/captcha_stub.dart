import 'package:flutter/material.dart';

/// Nowhere to draw a Turnstile widget.
///
/// Android and iOS: Turnstile is a browser widget and needs a webview,
/// which this app does not carry. `CaptchaField` says so on the screen
/// rather than drawing this, so this is only ever the compile-time
/// other half of the conditional import.
class TurnstileWidget extends StatelessWidget {
  const TurnstileWidget({
    super.key,
    required this.siteKey,
    required this.onToken,
  });

  final String siteKey;
  final ValueChanged<String?> onToken;

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
