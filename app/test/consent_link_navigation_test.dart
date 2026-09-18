/// Reading the terms and getting back to the form.
///
/// Reported as: tapping "terms of service" or "privacy policy" under the
/// register button opens the page, and the back button then leaves the
/// app instead of returning to the half-filled form.
///
/// The cause is one word. `context.go` REPLACES the location, so there
/// is nothing behind the page it opens; `context.push` puts it on the
/// stack. On the web that shows up as the browser's back button leaving
/// the site; on a phone the system back gesture closes the app.
///
/// It matters more under a consent sentence than anywhere else on the
/// platform. The link is there so somebody reads the terms before
/// agreeing to them, and losing the form for doing it is a punishment
/// for reading them.
///
/// Asserted through a real `GoRouter`, because that is the thing whose
/// behaviour is in question: a fake would assert my belief about `go`
/// and `push` rather than what they do.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

void main() {
  /// Two screens and the two ways of getting from one to the other.
  Future<GoRouter> open(WidgetTester t, {required bool usePush}) async {
    final router = GoRouter(
      initialLocation: '/signin',
      routes: [
        GoRoute(
          path: '/signin',
          builder: (context, _) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => usePush
                    ? context.push('/terms-of-service')
                    : context.go('/terms-of-service'),
                child: const Text('terms of service'),
              ),
            ),
          ),
        ),
        GoRoute(
          path: '/terms-of-service',
          builder: (context, _) => Scaffold(
            body: Center(
              child: TextButton(
                key: const ValueKey('site-page-back'),
                onPressed: () =>
                    context.canPop() ? context.pop() : context.go('/'),
                child: Text(context.canPop() ? 'Back' : 'Back to iAkauntan'),
              ),
            ),
          ),
        ),
        GoRoute(
          path: '/',
          builder: (_, _) => const Scaffold(body: Text('front page')),
        ),
      ],
    );
    await t.pumpWidget(MaterialApp.router(routerConfig: router));
    await t.pumpAndSettle();
    return router;
  }

  testWidgets('pushing leaves the form to come back to', (t) async {
    await open(t, usePush: true);

    await t.tap(find.text('terms of service'));
    await t.pumpAndSettle();

    // The page opened, and there is somewhere behind it.
    expect(find.byKey(const ValueKey('site-page-back')), findsOneWidget);
    expect(find.text('Back'), findsOneWidget);
    expect(find.text('Back to iAkauntan'), findsNothing);

    await t.tap(find.byKey(const ValueKey('site-page-back')));
    await t.pumpAndSettle();

    // Back on the form, not on the front page and not out of the app.
    expect(find.text('terms of service'), findsOneWidget);
    expect(find.text('front page'), findsNothing);
  });

  testWidgets('and `go` is what left nothing behind it', (t) async {
    // The control, and the reason this file exists rather than a
    // comment. Without it, "push works" would be an assertion about a
    // router that might behave the same either way.
    await open(t, usePush: false);

    await t.tap(find.text('terms of service'));
    await t.pumpAndSettle();

    // The page is there, and the form is gone from under it: nothing to
    // pop back to, so the button offers the front page instead.
    expect(find.text('Back to iAkauntan'), findsOneWidget);
    expect(find.text('Back'), findsNothing);
  });

  testWidgets('reached directly, the button still goes somewhere', (t) async {
    // Somebody who typed the address, or followed it from the footer
    // where the front page really is what is behind it. `canPop` is
    // false and the label says where it goes.
    final router = GoRouter(
      initialLocation: '/terms-of-service',
      routes: [
        GoRoute(
          path: '/terms-of-service',
          builder: (context, _) => Scaffold(
            body: TextButton(
              onPressed: () =>
                  context.canPop() ? context.pop() : context.go('/'),
              child: Text(context.canPop() ? 'Back' : 'Back to iAkauntan'),
            ),
          ),
        ),
        GoRoute(
          path: '/',
          builder: (_, _) => const Scaffold(body: Text('front page')),
        ),
      ],
    );
    await t.pumpWidget(MaterialApp.router(routerConfig: router));
    await t.pumpAndSettle();

    expect(find.text('Back to iAkauntan'), findsOneWidget);
    await t.tap(find.text('Back to iAkauntan'));
    await t.pumpAndSettle();
    expect(find.text('front page'), findsOneWidget);
  });
}
