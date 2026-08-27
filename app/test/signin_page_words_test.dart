import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iakauntan/src/core/env.dart';
import 'package:iakauntan/src/data/reserved_names_repository.dart';
import 'package:iakauntan/src/data/site_pages_repository.dart';
import 'package:iakauntan/src/features/auth/sign_in_screen.dart';
import 'package:iakauntan/src/features/landing/landing_content.dart';

/// The colour and the words on the sign-in form.
///
/// `0336` took the panel's copy out of the Dart; this covers what it
/// left behind. The failures worth catching are the ones that look like
/// a working screen: a console field that saves and never appears, and
/// a panel colour an operator chose that nobody can read text on.
void main() {
  Widget wrap(LandingContent brand, {String? workspaceName}) => ProviderScope(
    overrides: [
      landingContentProvider.overrideWith((ref) async => brand),
      workspaceHostProvider.overrideWith(
        (ref) async =>
            workspaceName == null ? null : {'name': workspaceName},
      ),
      sitePagesProvider.overrideWith((ref) async => const {}),
      workspaceLookupProvider.overrideWith(
        (ref) async => workspaceName == null
            ? (host: WorkspaceHost.platform, workspace: null)
            : (
                host: WorkspaceHost.found,
                workspace: <String, dynamic>{'name': workspaceName},
              ),
      ),
    ],
    child: const MaterialApp(home: SignInScreen()),
  );

  setUp(() {
    final view = TestWidgetsFlutterBinding.instance.platformDispatcher
        .views
        .first;
    view.physicalSize = const Size(1600, 2400);
    view.devicePixelRatio = 1.0;
    addTearDown(view.reset);
  });

  group('the words on the form', () {
    testWidgets('are the shipped ones when nobody has written any',
        (tester) async {
      await tester.pumpWidget(wrap(LandingContent.fallback));
      await tester.pumpAndSettle();

      // Null must mean "the word we ship", never an unlabelled box.
      expect(find.text('Email'), findsOneWidget);
      expect(find.text('Password'), findsOneWidget);
      expect(find.text('Forgot password?'), findsOneWidget);
      expect(find.text('Sign in'), findsOneWidget);
    });

    testWidgets('and the operator\'s own when they have', (tester) async {
      await tester.pumpWidget(wrap(const LandingContent(
        published: true,
        signinEmailLabel: 'E-mel',
        signinPasswordLabel: 'Kata laluan',
        signinForgotLabel: 'Lupa kata laluan?',
        signInLabel: 'Log masuk',
      )));
      await tester.pumpAndSettle();

      expect(find.text('E-mel'), findsOneWidget);
      expect(find.text('Kata laluan'), findsOneWidget);
      expect(find.text('Lupa kata laluan?'), findsOneWidget);
      expect(find.text('Log masuk'), findsOneWidget);

      expect(find.text('Email'), findsNothing);
      expect(find.text('Password'), findsNothing);
      expect(find.text('Sign in'), findsNothing);
    });

    testWidgets('including the sentence offering an account', (tester) async {
      await tester.pumpWidget(wrap(const LandingContent(
        published: true,
        signinShowRegister: true,
        signinRegisterPrompt: 'Baru di sini? Buka akaun',
      )));
      await tester.pumpAndSettle();

      expect(find.text('Baru di sini? Buka akaun'), findsOneWidget);
      expect(find.textContaining('New to'), findsNothing);
    });
  });

  group('the mark', () {
    testWidgets('draws no icon of ours when no logo is set', (tester) async {
      // Until 0337 this fell back to a compiled-in wallet, which is this
      // product's mark on somebody else's sign-in page — and a visitor
      // cannot tell it from a real logo.
      await tester.pumpWidget(wrap(const LandingContent(
        published: true,
        logoUrl: null,
        wordmark: 'Sesuatu',
        signinShowLogo: true,
        signinShowName: true,
      )));
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.account_balance_wallet), findsNothing);
      expect(find.text('Sesuatu'), findsWidgets);
    });

    testWidgets('and names the platform from the payload, not a literal',
        (tester) async {
      await tester.pumpWidget(wrap(const LandingContent(
        published: true,
        logoUrl: null,
        wordmark: 'Kira Kira',
        signinShowLogo: true,
        signinShowName: true,
      )));
      await tester.pumpAndSettle();

      expect(find.text('Kira Kira'), findsWidgets);
      expect(find.text(Env.appName), findsNothing);
    });
  });

  group('the payload', () {
    test('carries the words and the colour beside brand', () {
      final content = parseLandingContent(const {
        'brand': {
          'signin_email_label': 'E-mel',
          'signin_password_label': 'Kata laluan',
          'signin_name_label': 'Nama penuh',
          'signin_forgot_label': 'Lupa?',
          'signin_register_prompt': 'Baru?',
          'signin_signin_prompt': 'Sudah ada?',
          'sign_in_label': 'Log masuk',
          'register_label': 'Buka akaun',
        },
      });

      // Unpublished, which is the branch this screen is usually on.
      expect(content.published, isFalse);
      expect(content.signinEmailLabel, 'E-mel');
      expect(content.signinPasswordLabel, 'Kata laluan');
      expect(content.signinNameLabel, 'Nama penuh');
      expect(content.signinForgotLabel, 'Lupa?');
      expect(content.signinRegisterPrompt, 'Baru?');
      expect(content.signinSigninPrompt, 'Sudah ada?');
      // The two that were read out of `page` only until 0337, so an
      // unpublished site fell back to the literals.
      expect(content.signInLabel, 'Log masuk');
      expect(content.registerLabel, 'Buka akaun');
    });

    test('reads the two button labels from brand even when published', () {
      // On a published payload `page` carries these columns too, so
      // brand-first and page-only agree today. They stop agreeing the
      // day the column leaves `page` — and the screen that would break
      // is the one nobody can route around, so pin which side wins.
      final content = parseLandingContent(const {
        'page': {'is_published': true},
        'brand': {'sign_in_label': 'Log masuk'},
      });

      expect(content.published, isTrue);
      expect(content.signInLabel, 'Log masuk');
    });

    test('and leaves them unwritten when nobody has said', () {
      final content = parseLandingContent(const {'brand': {}});

      expect(content.signinEmailLabel, isNull);
      expect(content.signinRegisterPrompt, isNull);
      // These two are NOT NULL in the database, so the shipped word is
      // the right answer rather than null.
      expect(content.signInLabel, 'Sign in');
      expect(content.registerLabel, 'Create an account');
    });
  });
}
