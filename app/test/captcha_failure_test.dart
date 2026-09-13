import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/features/auth/captcha.dart';

/// A security check that will not draw.
///
/// This is the state production was in: `script-src 'self'` refused
/// Cloudflare's script, the widget never rendered, and the form went on
/// saying "Complete the security check first" about a check that was
/// not on the screen. The person reading it could do nothing, and
/// nothing anywhere said why.
///
/// The widget cannot be driven from a test — it needs a browser and
/// Cloudflare — so what is asserted here is the part that failed: that
/// the two situations have DIFFERENT words, and that the words for a
/// broken check say who can fix it.
void main() {
  group('the two refusals', () {
    test('are not the same sentence', () {
      // The bug, in one assertion. If these ever collapse into one
      // string, somebody looking at an empty box is being told to fill
      // it in.
      expect(captchaBroken, isNot(captchaNotDone));
    });

    test('and only one of them is something to do', () {
      // "Complete the security check first" is an instruction. It is
      // the right words only when there is a check to complete.
      expect(captchaNotDone.toLowerCase(), contains('complete'));

      // The other is a report. It must not tell somebody to do the
      // thing they cannot do.
      expect(captchaBroken.toLowerCase(), isNot(contains('complete')));
      expect(captchaBroken.toLowerCase(), contains('could not load'));
    });

    test('and the broken one does not blame the reader', () {
      // Somebody who cannot sign in because of a header on our server
      // should not be left thinking they failed a test.
      expect(captchaBroken.toLowerCase(), contains('rather than by you'));
    });
  });

  group('the field', () {
    testWidgets('draws nothing at all when no key is configured', (t) async {
      // Empty means off, which is what every form did before the
      // captcha existed.
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CaptchaField(siteKey: '  ', onToken: (_) {}),
          ),
        ),
      );
      expect(find.byType(Text), findsNothing);
    });

    testWidgets('says so on a platform that cannot draw one', (t) async {
      // The test runner is not a browser, so `captchaAvailable` is
      // false — the same answer Android and iOS give. A form that
      // silently drew nothing here would be a form demanding a token
      // no platform could produce.
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CaptchaField(siteKey: 'a-site-key', onToken: (_) {}),
          ),
        ),
      );
      expect(find.text(captchaUnavailable), findsOneWidget);
    });

    testWidgets('and does not report a failure it has not had', (t) async {
      // `onFailed` is what turns the form's message from an instruction
      // into a report, so it firing when nothing went wrong would be
      // its own bug.
      var failed = false;
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CaptchaField(
              siteKey: 'a-site-key',
              onToken: (_) {},
              onFailed: () => failed = true,
            ),
          ),
        ),
      );
      await t.pump(const Duration(seconds: 1));
      expect(failed, isFalse);
    });
  });
}
