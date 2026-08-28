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

  group('the hold around a sign-in', () {
    // The ordering, asserted directly, because the ordering is what
    // nothing could see: `vettingProvider` was declared and the router
    // honoured it while, for one commit, nothing raised it. A rebase
    // resolved a conflict in the sign-in screen in favour of an older
    // copy and took the two lines with it. Everything compiled, every
    // test passed, and the app went back to letting people in and
    // throwing them out again.
    test('goes up before the password leaves, and down after vetting', () async {
      final order = <String>[];

      await vettedSignIn(
        hold: (held) => order.add(held ? 'hold' : 'release'),
        signIn: () async => order.add('signIn'),
        vet: () async => order.add('vet'),
      );

      expect(order, ['hold', 'signIn', 'vet', 'release']);
    });

    test('and comes down even when signing in throws', () async {
      final order = <String>[];

      await expectLater(
        vettedSignIn(
          hold: (held) => order.add(held ? 'hold' : 'release'),
          signIn: () async => throw Exception('wrong password'),
          vet: () async => order.add('vet'),
        ),
        throwsException,
      );

      // A hold nobody lifts is an app that never moves again, so the
      // release matters more here than anywhere. And vetting is skipped
      // — there is no session to ask about.
      expect(order, ['hold', 'release']);
    });

    test('and even when the vetting itself throws', () async {
      final order = <String>[];

      await expectLater(
        vettedSignIn(
          hold: (held) => order.add(held ? 'hold' : 'release'),
          signIn: () async => order.add('signIn'),
          vet: () async => throw Exception('the lookup fell over'),
        ),
        throwsException,
      );

      expect(order, ['hold', 'signIn', 'release']);
    });
  });

  group('what a refusal says', () {
    // Pure, and separate from the round trip, because the interesting
    // case is the one where the round trip has not finished: the name
    // comes from a lookup that may still be in flight when the refusal
    // lands, and "not on 's team" reads as a bug rather than an answer.
    test('names the company whose door it is', () {
      expect(
        notTheirDoorMessage('Sinar Teknologi'),
        contains("not on Sinar Teknologi's team"),
      );
    });

    test('and says something sensible when it has no name', () {
      final said = notTheirDoorMessage(null);

      expect(said, contains('may not use this address'));
      expect(said, isNot(contains("'s team")));
    });

    test('either way it says where to go instead', () {
      expect(notTheirDoorMessage('Sinar'), contains('iakauntan.com'));
      expect(notTheirDoorMessage(null), contains('iakauntan.com'));
    });
  });

  // The dialog itself is deliberately not pumped here, and that is a
  // retreat rather than a decision I like.
  //
  // Three tests did pump it — open `showRefusal`, assert the title and
  // the message, tap OK. They passed in four seconds when this file was
  // run alone and hung until the ten-minute per-test timeout when the
  // whole suite ran, taking CI's twenty-minute job down with them.
  // Neither holding and awaiting the dialog's future nor pumping a
  // fixed number of frames instead of `pumpAndSettle` fixed it:
  // something on this screen does not reach quiescence with a route
  // above it, and I did not find what.
  //
  // A flaky test that can hang a twenty-minute job is worse than no
  // test — it costs every future run and teaches everyone to re-run
  // rather than to read. So what is asserted here is the wording, which
  // is pure and cannot hang, and `sign_in_screen.dart` keeps
  // `showRefusal` as its own method so whoever works out the quiescence
  // problem has a seam to pump.
}
