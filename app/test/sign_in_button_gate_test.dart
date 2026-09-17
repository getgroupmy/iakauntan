import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iakauntan/src/data/reserved_names_repository.dart';
import 'package:iakauntan/src/features/auth/sign_in_screen.dart';
import 'package:iakauntan/src/features/landing/landing_content.dart';

/// When the Sign in button may be pressed.
///
/// It used to be pressable always, and refuse on press: "Complete the
/// security check first", said about a check sitting directly above the
/// button with its own answer on it. A press that tells somebody
/// something they could already see is a press that taught them
/// nothing.
///
/// So the button is disabled until the form has what it needs, and the
/// three conditions are asserted here because each one has a way of
/// being wrong that is invisible:
///
///   * a deployment with NO captcha key must not wait for a token that
///     is never coming;
///   * a company's door asks the address first and does not draw a
///     password box at all, so requiring a password there would be a
///     button that never enables;
///   * and the form has to redraw as the boxes are typed in, which a
///     `TextFormField` with a controller does not do on its own.
void main() {
  setUp(() {
    final view = TestWidgetsFlutterBinding.ensureInitialized()
        .platformDispatcher
        .views
        .first;
    view.physicalSize = const Size(1600, 2400);
    view.devicePixelRatio = 1.0;
  });
  tearDown(() {
    final view = TestWidgetsFlutterBinding.ensureInitialized()
        .platformDispatcher
        .views
        .first;
    view.resetPhysicalSize();
    view.resetDevicePixelRatio();
  });

  Widget wrap({String? siteKey}) => ProviderScope(
    overrides: [
      workspaceHostProvider.overrideWith((ref) async => null),
      workspaceLookupProvider.overrideWith(
        (ref) async => (host: WorkspaceHost.platform, workspace: null),
      ),
      landingContentProvider.overrideWith(
        (ref) async =>
            LandingContent(published: true, turnstileSiteKey: siteKey),
      ),
    ],
    child: const MaterialApp(home: SignInScreen()),
  );

  /// The Sign in button, whatever it currently says.
  FilledButton signInButton(WidgetTester t) =>
      t.widget<FilledButton>(find.byType(FilledButton).first);

  testWidgets('is off until both boxes are filled in', (t) async {
    // No site key: the captcha is not part of this, so what is left is
    // the email and the password.
    await t.pumpWidget(wrap());
    await t.pumpAndSettle();

    expect(signInButton(t).onPressed, isNull, reason: 'empty form');

    await t.enterText(find.byType(TextFormField).first, 'somebody@example.com');
    await t.pump();
    // An address on its own is not a sign-in.
    expect(signInButton(t).onPressed, isNull, reason: 'no password yet');

    await t.enterText(find.byType(TextFormField).at(1), 'a-password');
    await t.pump();
    expect(signInButton(t).onPressed, isNotNull, reason: 'both filled in');
  });

  testWidgets('and goes off again when a box is cleared', (t) async {
    await t.pumpWidget(wrap());
    await t.pumpAndSettle();

    await t.enterText(find.byType(TextFormField).first, 'somebody@example.com');
    await t.enterText(find.byType(TextFormField).at(1), 'a-password');
    await t.pump();
    expect(signInButton(t).onPressed, isNotNull);

    // The listener has to fire in both directions. Watching only for
    // "now ready" would leave the button lit over an empty box.
    await t.enterText(find.byType(TextFormField).at(1), '');
    await t.pump();
    expect(signInButton(t).onPressed, isNull);
  });

  testWidgets('and waits for the security check when one is configured', (
    t,
  ) async {
    // A key is set, so a token is required. This runner is not a
    // browser, so no token can ever arrive — which is the same
    // position Android and iOS are in, and the note the field draws
    // above the button says so. The button being off is the honest
    // rendering of that.
    await t.pumpWidget(wrap(siteKey: 'a-site-key'));
    await t.pumpAndSettle();

    await t.enterText(find.byType(TextFormField).first, 'somebody@example.com');
    await t.enterText(find.byType(TextFormField).at(1), 'a-password');
    await t.pump();

    expect(signInButton(t).onPressed, isNull);
  });
}
