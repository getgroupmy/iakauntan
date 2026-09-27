import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/core/theme.dart';
import 'package:iakauntan/src/data/landing_repository.dart';
import 'package:iakauntan/src/features/admin/landing_cms.dart';
import 'package:iakauntan/src/features/landing/landing_content.dart';
import 'package:iakauntan/src/features/landing/landing_screen.dart';

/// The front page as an operator sees it before anybody else does.
///
/// Two things had never been built by a test: `LandingCmsTab`, which is
/// not a `*Screen` and not a dialog opener and so fell between both
/// gates; and the preview behind its Preview button, which is a private
/// screen and the reason `check_screens_built.py` still carries an
/// EXEMPT entry.
///
/// A private class cannot be NAMED from another library, so this reaches
/// it the way the app does — by pressing the button — and asserts on
/// something only the preview renders. That is a stronger test than
/// naming the constructor would have been: it proves the door works as
/// well as the room behind it.
void main() {
  Widget harness() => ProviderScope(
        overrides: [
          landingPageAdminProvider.overrideWith((_) async => const {
                'slug': 'landing',
                'is_published': false,
                'wordmark': 'iAkauntan',
                'hero_headline': 'Books that balance',
              }),
          landingSectionsAdminProvider.overrideWith((_) async => const []),
          landingStatsAdminProvider.overrideWith((_) async => const []),
          landingTestimonialsAdminProvider.overrideWith((_) async => const []),
          landingLogosAdminProvider.overrideWith((_) async => const []),
          landingAppLinksAdminProvider.overrideWith((_) async => const []),
          landingPreviewProvider.overrideWith(
            (_) async => const LandingContent(
              published: false,
              wordmark: 'iAkauntan',
              heroHeadline: 'Books that balance, on a phone',
            ),
          ),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const Scaffold(body: LandingCmsTab()),
        ),
      );

  testWidgets('the editor builds, and says the page is a draft',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    // A draft is the dangerous state to be unclear about: somebody
    // looking at a finished-looking editor should know visitors are not
    // seeing it.
    expect(
      find.textContaining('This page is a draft'),
      findsOneWidget,
    );
    expect(find.text('Preview'), findsOneWidget);
  });

  testWidgets('and Preview opens the draft as a visitor would see it',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Preview'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    // The private preview screen, reached through the button rather than
    // named: its own app bar, its own sentence, and the real landing
    // page underneath rather than a second set of widgets that would
    // drift from the page it claims to preview.
    expect(
      find.text('The draft, as it will look once published.'),
      findsOneWidget,
    );
    expect(find.byType(LandingPage), findsOneWidget);
    expect(
      find.textContaining('Books that balance, on a phone'),
      findsWidgets,
      reason: 'the preview shows the DRAFT, not what is published',
    );
  });
}
