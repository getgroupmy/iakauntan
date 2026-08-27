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

  Widget wrap({Map<String, dynamic>? workspace}) => ProviderScope(
        overrides: [
          workspaceHostProvider.overrideWith((ref) async => workspace),
          workspaceLookupProvider.overrideWith(
            (ref) async => workspace == null
                ? (host: WorkspaceHost.platform, workspace: null)
                : (host: WorkspaceHost.found, workspace: workspace),
          ),
          landingContentProvider.overrideWith(
            (ref) async => LandingContent.fallback,
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
}
