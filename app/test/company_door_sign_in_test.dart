import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iakauntan/src/data/reserved_names_repository.dart';
import 'package:iakauntan/src/features/auth/sign_in_screen.dart';
import 'package:iakauntan/src/features/landing/landing_content.dart';

/// What the sign-in page offers at a company's own address.
///
/// Everything below the Sign in button is about joining the platform,
/// and none of it belongs on Sinar's door. This was checked by looking
/// at a screenshot and the screenshot was of a stale bundle, which is
/// exactly the reason to assert it instead.
void main() {
  // The sign-in screen is two columns on a wide window and the demo
  // list is long. At the default 800x600 test surface it overflows and
  // the failure is about pixels rather than about what is on the page.
  setUp(() {
    final view = TestWidgetsFlutterBinding.ensureInitialized().platformDispatcher
        .views.first;
    view.physicalSize = const Size(1600, 2400);
    view.devicePixelRatio = 1.0;
  });
  tearDown(() {
    final view = TestWidgetsFlutterBinding.ensureInitialized().platformDispatcher
        .views.first;
    view.resetPhysicalSize();
    view.resetDevicePixelRatio();
  });

  // `signinShowRegister` is on throughout, because what is asserted
  // here is the company-door rule and not `0336`'s switch: with the
  // switch off the link is absent everywhere, and "absent on Sinar's
  // door" would pass without the rule existing at all.
  Widget wrap({Map<String, dynamic>? workspace}) => ProviderScope(
        overrides: [
          workspaceHostProvider.overrideWith((ref) async => workspace),
          workspaceLookupProvider.overrideWith(
            (ref) async => workspace == null
                ? (host: WorkspaceHost.platform, workspace: null)
                : (host: WorkspaceHost.found, workspace: workspace),
          ),
          landingContentProvider.overrideWith(
            (ref) async => const LandingContent(
              published: true,
              signinShowRegister: true,
            ),
          ),
        ],
        child: const MaterialApp(home: SignInScreen()),
      );

  testWidgets('a company door offers no way to join the platform',
      (tester) async {
    await tester.pumpWidget(wrap(workspace: {'name': 'Sinar Teknologi Sdn Bhd'}));
    await tester.pumpAndSettle();

    expect(find.textContaining('Create an account'), findsNothing);
    expect(find.textContaining('look around a demo'), findsNothing);
    expect(find.textContaining('Owner'), findsNothing);
  });

  testWidgets('and says whose door it is', (tester) async {
    await tester.pumpWidget(wrap(workspace: {'name': 'Sinar Teknologi Sdn Bhd'}));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('Sinar Teknologi Sdn Bhd'),
      findsWidgets,
      reason: 'the whole point of the page is that it is theirs',
    );
  });

  testWidgets('the bare domain keeps both', (tester) async {
    // The other half of the assertion. Hiding these everywhere would
    // pass the test above and take the front door off the product.
    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();

    expect(find.textContaining('Create an account'), findsWidgets);
  });

  group('a refusal at the door', () {
    // `0346`, and the shape rather than the rule. Somebody signing in
    // with the wrong account for this address used to be let in and
    // then shown a whole screen saying no — a screen where a sentence
    // would do, and one they arrive at signed in to a product they
    // cannot use. Now they are turned back on the form they were
    // already looking at.
    Future<void> refuseOn(WidgetTester tester, String title, String message)
        async {
      await tester.pumpWidget(wrap(workspace: const {'name': 'Sinar'}));
      await tester.pumpAndSettle();
      // Deliberately not awaited: the future completes when the dialog
      // is dismissed, so awaiting it here waits for a tap that this
      // line is what makes possible.
      unawaited(
        tester.state<SignInScreenState>(find.byType(SignInScreen))
            .showRefusal(title: title, message: message),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('says which module, in a dialog', (tester) async {
      await refuseOn(tester, 'Not activated',
          'This address opens Point of Sale, and that is not switched on.');

      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.text('Not activated'), findsOneWidget);
      expect(find.textContaining('Point of Sale'), findsOneWidget);
    });

    testWidgets('and leaves the form where it was', (tester) async {
      await refuseOn(tester, 'Not your workspace', 'Not on Sinar\'s team.');

      // The whole point of the change: the sign-in form is still there
      // behind the dialog, so the next thing to do — sign in as
      // somebody else — is the thing already on screen.
      expect(find.byType(TextFormField), findsWidgets);
      expect(find.byType(AlertDialog), findsOneWidget);
    });

    testWidgets('and closes on OK, leaving the form', (tester) async {
      await refuseOn(tester, 'Not activated', 'No till here.');

      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsNothing);
      expect(find.byType(TextFormField), findsWidgets);
    });
  });
}
