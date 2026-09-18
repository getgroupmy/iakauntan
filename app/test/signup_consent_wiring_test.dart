import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iakauntan/src/data/reserved_names_repository.dart';
import 'package:iakauntan/src/data/site_pages_repository.dart';
import 'package:iakauntan/src/features/auth/sign_in_screen.dart';
import 'package:iakauntan/src/features/landing/landing_content.dart';

/// The consent line, on the screen rather than in a function.
///
/// `signup_consent_test.dart` asserts the wording; this asserts it is
/// actually attached to the button it describes — which is the half
/// that cannot be checked without a widget, and the half that would
/// otherwise ship as a sentence nobody sees.
///
/// Both surfaces get it because there is one form: the sign-in screen
/// is the same widget on web, Android and iOS, so wiring it once wires
/// it everywhere. The thing worth asserting is not the platform but
/// the HALF — it must be under the register button and not under the
/// sign-in one, where "By clicking Create account" would be a sentence
/// about something that is not happening.
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

  Widget wrap({
    bool startOnRegister = true,
    String registerLabel = 'Create an account',
    String? wordmark,
    Map<String, SitePage> pages = const {},
  }) => ProviderScope(
    overrides: [
      workspaceHostProvider.overrideWith((ref) async => null),
      workspaceLookupProvider.overrideWith(
        (ref) async => (host: WorkspaceHost.platform, workspace: null),
      ),
      landingContentProvider.overrideWith(
        (ref) async => LandingContent(
          published: true,
          registerLabel: registerLabel,
          wordmark: wordmark ?? 'iAkauntan',
        ),
      ),
      sitePagesProvider.overrideWith((ref) async => pages),
    ],
    child: MaterialApp(home: SignInScreen(startOnRegister: startOnRegister)),
  );

  const published = {
    'terms-of-service': SitePage(
      slug: 'terms-of-service',
      isPublished: true,
    ),
    'privacy': SitePage(slug: 'privacy', isPublished: true),
  };

  testWidgets('it is under the register button', (t) async {
    await t.pumpWidget(wrap(pages: published));
    await t.pumpAndSettle();

    expect(find.byKey(const ValueKey('signup-consent')), findsOneWidget);
  });

  testWidgets('and not under the sign-in button', (t) async {
    // The sentence describes registering. Under a Sign in button it
    // would be claiming somebody agreed to terms by doing something
    // else entirely.
    await t.pumpWidget(wrap(startOnRegister: false, pages: published));
    await t.pumpAndSettle();

    expect(find.byKey(const ValueKey('signup-consent')), findsNothing);
  });

  testWidgets('it quotes whatever the console called the button', (t) async {
    await t.pumpWidget(
      wrap(registerLabel: 'Daftar Sekarang', pages: published),
    );
    await t.pumpAndSettle();

    final text = t.widget<Text>(find.byKey(const ValueKey('signup-consent')));
    expect(text.textSpan!.toPlainText(), contains('"Daftar Sekarang"'));
    // And the button really does say that, so the quotation is of
    // something visible rather than of a setting.
    expect(find.text('Daftar Sekarang'), findsOneWidget);
  });

  testWidgets('and names whatever the console called the platform', (t) async {
    await t.pumpWidget(wrap(wordmark: 'Sinar Kira', pages: published));
    await t.pumpAndSettle();

    final text = t.widget<Text>(find.byKey(const ValueKey('signup-consent')));
    expect(text.textSpan!.toPlainText(), contains("Sinar Kira's"));
    expect(text.textSpan!.toPlainText(), isNot(contains('iAkauntan')));
  });

  testWidgets('the default wording is the one that was asked for', (t) async {
    // "Create an account" and not "Register": that is what
    // `LandingContent.registerLabel` ships as and therefore what the
    // button says. The sentence follows the button, which is the whole
    // reason the label is passed in rather than written down.
    await t.pumpWidget(wrap(pages: published));
    await t.pumpAndSettle();

    final text = t.widget<Text>(find.byKey(const ValueKey('signup-consent')));
    expect(
      text.textSpan!.toPlainText(),
      'By clicking "Create an account", you agree to iAkauntan\'s terms '
          'of service and privacy policy.',
    );
    expect(find.text('Create an account'), findsWidgets);
  });

  testWidgets('an unpublished page is named but not offered as a link', (
    t,
  ) async {
    // A link to an unpublished page lands on "this page has not been
    // written yet", under a sentence saying the reader has agreed to
    // it. The words stay; the link does not.
    await t.pumpWidget(
      wrap(
        pages: const {
          'privacy': SitePage(slug: 'privacy', isPublished: true),
          'terms-of-service': SitePage(
            slug: 'terms-of-service',
            isPublished: false,
          ),
        },
      ),
    );
    await t.pumpAndSettle();

    final text = t.widget<Text>(find.byKey(const ValueKey('signup-consent')));
    final plain = text.textSpan!.toPlainText();
    expect(plain, contains('terms of service'));

    // Two spans carry a tap recognizer when both are published; one
    // here, because only privacy is.
    final tappable = <String>[];
    text.textSpan!.visitChildren((span) {
      if (span is TextSpan && span.recognizer != null) {
        tappable.add(span.text ?? '');
      }
      return true;
    });
    expect(tappable, ['privacy policy']);
  });

  testWidgets('with both published, both are links', (t) async {
    // The control for the assertion above: without it, a sentence that
    // never linked anything would pass it.
    await t.pumpWidget(wrap(pages: published));
    await t.pumpAndSettle();

    final text = t.widget<Text>(find.byKey(const ValueKey('signup-consent')));
    final tappable = <String>[];
    text.textSpan!.visitChildren((span) {
      if (span is TextSpan && span.recognizer != null) {
        tappable.add(span.text ?? '');
      }
      return true;
    });
    expect(tappable, ['terms of service', 'privacy policy']);
  });

  testWidgets('a screen reader is handed the whole sentence', (t) async {
    // Five spans read aloud one at a time is a legal notice delivered
    // as fragments.
    await t.pumpWidget(wrap(pages: published));
    await t.pumpAndSettle();

    final semantics = t.widget<Semantics>(
      find
          .ancestor(
            of: find.byKey(const ValueKey('signup-consent')),
            matching: find.byType(Semantics),
          )
          .first,
    );
    expect(
      semantics.properties.label,
      contains('you agree to'),
    );
  });
}
