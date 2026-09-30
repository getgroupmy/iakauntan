import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iakauntan/src/data/reserved_names_repository.dart';
import 'package:iakauntan/src/data/signup_reference_repository.dart';
import 'package:iakauntan/src/features/auth/sign_in_screen.dart';
import 'package:iakauntan/src/features/landing/landing_content.dart';
import 'package:iakauntan/src/features/onboarding/onboarding_copy.dart';

/// What registration asks, and what setup therefore does not have to.
///
/// Two separate points, and the second is the one worth protecting.
///
/// The form asks three questions now rather than two, because an
/// accounting practice is not a kind of business: it is somebody
/// opening a list of OTHER people's books, and what follows from that
/// answer — Multi-Company from the start, no "what kind of business?"
/// — follows from nothing else on the page.
///
/// And a business is asked for its name and its legal form HERE.
/// Setup's opening act was to ask a company for its name, ten seconds
/// after somebody typed their company's name into the form above.
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

  Widget wrap([
    LandingContent content = const LandingContent(
      published: true,
      signinShowRegister: true,
    ),
  ]) => ProviderScope(
    overrides: [
      workspaceHostProvider.overrideWith((ref) async => null),
      workspaceLookupProvider.overrideWith(
        (ref) async => (host: WorkspaceHost.platform, workspace: null),
      ),
      landingContentProvider.overrideWith((ref) async => content),
      signupReferenceProvider.overrideWith(
        (ref) async => (
          dialCodes: const [
            {'code': 'MYS', 'dial_code': '60', 'name': 'Malaysia'},
          ],
          salutations: const [
            {'name': 'Encik', 'grouping': 'common', 'code': 'encik'},
          ],
          states: const [
            {'code': '10', 'name': 'Selangor'},
          ],
          entityTypes: const [
            {'code': 'sdn_bhd', 'label': 'Sdn Bhd'},
            {'code': 'bhd', 'label': 'Berhad'},
          ],
          signupsOpen: true,
          closedMessage: null,
        ),
      ),
    ],
    child: const MaterialApp(home: SignInScreen()),
  );

  Future<void> openRegistration(
    WidgetTester tester, [
    LandingContent content = const LandingContent(
      published: true,
      signinShowRegister: true,
    ),
  ]) async {
    await tester.pumpWidget(wrap(content));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('Create an account'));
    await tester.pumpAndSettle();
  }

  testWidgets('three answers, and each says what it does', (tester) async {
    await openRegistration(tester);

    final segmented = tester.widget<SegmentedButton<UseKind>>(
      find.byKey(const ValueKey('signup-use')),
    );
    expect(segmented.segments.map((s) => s.value).toList(), [
      UseKind.business,
      UseKind.accountant,
      UseKind.personal,
    ]);

    // A word on a segment cannot say that "Accountant" brings
    // Multi-Company with it, and somebody choosing between three
    // answers is entitled to know what each one does first.
    expect(find.text(businessBlurb), findsOneWidget);
  });

  testWidgets('a business is asked what it is called, here and not later', (
    tester,
  ) async {
    await openRegistration(tester);

    // Business is the answer the form starts on.
    expect(find.byKey(const ValueKey('signup-business-name')), findsOneWidget);
    final entity = tester.widget<DropdownButtonFormField<String>>(
      find.byKey(const ValueKey('signup-entity-type')),
    );
    expect(entity.initialValue, defaultEntityType);
  });

  testWidgets('a practice is not, and is told why', (tester) async {
    await openRegistration(tester);
    await tester.tap(find.text(accountantTitle));
    await tester.pumpAndSettle();

    // An accountant's own firm is set up on the setup form like any
    // company. Registration is not the moment to start collecting it,
    // and the firm is not the thing they came to register.
    expect(find.byKey(const ValueKey('signup-business-name')), findsNothing);
    expect(find.byKey(const ValueKey('signup-entity-type')), findsNothing);
    expect(find.text(accountantBlurb), findsOneWidget);
  });

  testWidgets('and a person has no company name at all', (tester) async {
    await openRegistration(tester);
    await tester.tap(find.text(personalTitle(SetupAudience.own)));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('signup-business-name')), findsNothing);
    expect(find.byKey(const ValueKey('signup-entity-type')), findsNothing);
  });

  testWidgets('the three answers fit a phone', (tester) async {
    // A SegmentedButton does not wrap — it clips. Two answers fitted
    // with an icon each; three do not, and the third would be a
    // truncated word somebody taps without being able to read it.
    final view = TestWidgetsFlutterBinding.ensureInitialized()
        .platformDispatcher
        .views
        .first;
    view.physicalSize = const Size(400, 2400);
    await openRegistration(tester);

    expect(tester.takeException(), isNull);
    final segmented = tester.widget<SegmentedButton<UseKind>>(
      find.byKey(const ValueKey('signup-use')),
    );
    for (final segment in segmented.segments) {
      expect(segment.icon, isNull);
    }
  });

  // ===================================================================
  // `0725`. Which answers this surface offers
  // ===================================================================
  //
  // Six switches, one per answer per surface, and the console can turn
  // any of them off. The unit rules are in `signup_kinds_test.dart`;
  // what is asserted here is that the FORM follows them — a question
  // with one answer is not asked, and a form with no answers left is
  // still a form somebody can submit.
  //
  // These read the MOBILE switches, and that is not a choice. A widget
  // test runs on the VM, so `kIsWeb` is false and
  // `defaultTargetPlatform` is `android` — which makes
  // `currentSurface` `Surface.android`. Writing these against the web
  // columns is exactly the mistake the six switches exist to make
  // possible, and it passed three of four tests before the surface was
  // checked rather than assumed.

  testWidgets('an answer the console withdrew is not offered', (tester) async {
    await openRegistration(
      tester,
      const LandingContent(
        published: true,
        signinShowRegister: true,
        signupShowAccountantMobile: false,
      ),
    );

    final segmented = tester.widget<SegmentedButton<UseKind>>(
      find.byKey(const ValueKey('signup-use')),
    );
    expect(segmented.segments.map((s) => s.value).toList(), [
      UseKind.business,
      UseKind.personal,
    ]);
  });

  testWidgets('one answer left is not a question, and is what is used', (
    tester,
  ) async {
    // A segmented bar with a single segment is a button that cannot be
    // pressed and cannot be unpressed, and it invites somebody to hunt
    // for the options that are not there.
    await openRegistration(
      tester,
      const LandingContent(
        published: true,
        signinShowRegister: true,
        signupShowBusinessMobile: false,
        signupShowAccountantMobile: false,
      ),
    );

    expect(find.byKey(const ValueKey('signup-use')), findsNothing);
    expect(find.text(useQuestion(SetupAudience.own)), findsNothing);
    // Registering as an individual, so no company name is asked for.
    // The form starts on `business`, so following the tapped answer
    // rather than the settled one would ask for one here.
    expect(find.byKey(const ValueKey('signup-business-name')), findsNothing);
    expect(find.text(personalBlurb(SetupAudience.own)), findsOneWidget);
  });

  testWidgets('and none left still registers somebody, as an individual', (
    tester,
  ) async {
    // NOT a form that cannot be submitted. An operator who switched all
    // three off said what they want the form to BE, and the individual
    // is the answer that needs nothing else to be true: no SSM number,
    // no registered name, no paid module.
    await openRegistration(
      tester,
      const LandingContent(
        published: true,
        signinShowRegister: true,
        signupShowBusinessMobile: false,
        signupShowAccountantMobile: false,
        signupShowPersonalMobile: false,
      ),
    );

    expect(find.byKey(const ValueKey('signup-use')), findsNothing);
    expect(find.byKey(const ValueKey('signup-business-name')), findsNothing);
    expect(find.text(personalBlurb(SetupAudience.own)), findsOneWidget);
  });

  testWidgets('withdrawing it on the website leaves the apps alone', (
    tester,
  ) async {
    // The whole reason there are six switches and not three. This is
    // the app surface, so all three web columns being off changes
    // nothing here.
    await openRegistration(
      tester,
      const LandingContent(
        published: true,
        signinShowRegister: true,
        signupShowBusinessWeb: false,
        signupShowAccountantWeb: false,
        signupShowPersonalWeb: false,
      ),
    );

    final segmented = tester.widget<SegmentedButton<UseKind>>(
      find.byKey(const ValueKey('signup-use')),
    );
    expect(segmented.segments, hasLength(3));
  });
}
