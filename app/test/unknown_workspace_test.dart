import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iakauntan/src/features/landing/landing_content.dart';
import 'package:iakauntan/src/features/landing/unknown_workspace_screen.dart';

/// The page a visitor gets at a subdomain nobody holds.
///
/// The failures worth catching are all about a visitor being told the
/// wrong thing: shipped copy that never appears because the operator
/// left the boxes empty, an operator's copy that never appears because
/// the payload is unpublished, or a button that sends somebody to a
/// host that does not exist.
void main() {
  Widget wrap(LandingContent? brand, {String host = 'nosuch.iakauntan.com'}) =>
      ProviderScope(
        overrides: [
          landingContentProvider.overrideWith(
            (ref) async => brand ?? LandingContent.fallback,
          ),
        ],
        child: MaterialApp(home: UnknownWorkspaceScreen(host: host)),
      );

  testWidgets('says so in the shipped words when nobody has written any',
      (tester) async {
    await tester.pumpWidget(wrap(null));
    await tester.pumpAndSettle();

    expect(find.text(LandingContent.defaultUnknownTitle), findsOneWidget);
    expect(find.text(LandingContent.defaultUnknownBody), findsOneWidget);
    expect(find.text(LandingContent.defaultUnknownCtaLabel), findsOneWidget);
  });

  testWidgets('prefers what the operator wrote', (tester) async {
    await tester.pumpWidget(wrap(const LandingContent(
      published: true,
      unknownTitle: 'Alamat ini tiada',
      unknownBody: 'Sila semak semula.',
      unknownCtaLabel: 'Ke laman utama',
    )));
    await tester.pumpAndSettle();

    expect(find.text('Alamat ini tiada'), findsOneWidget);
    expect(find.text('Sila semak semula.'), findsOneWidget);
    expect(find.text('Ke laman utama'), findsOneWidget);
    expect(find.text(LandingContent.defaultUnknownTitle), findsNothing);
  });

  testWidgets('shows the address, because "check for a typo" needs it',
      (tester) async {
    await tester.pumpWidget(wrap(null, host: 'sinarr.iakauntan.com'));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('unknown-workspace-host')),
      findsOneWidget,
    );
    expect(find.text('sinarr.iakauntan.com'), findsOneWidget);
  });

  testWidgets('an unpublished site still gets a page', (tester) async {
    // The case this screen exists for that is easiest to get wrong:
    // `LandingContent.fallback` is what an unpublished payload parses
    // to, and it must not be blank here.
    await tester.pumpWidget(wrap(LandingContent.fallback));
    await tester.pumpAndSettle();

    expect(find.text(LandingContent.defaultUnknownTitle), findsOneWidget);
  });

  group('apexOf', () {
    test('drops the company label', () {
      expect(apexOf('sinar.iakauntan.com'), 'iakauntan.com');
    });

    test('is case- and port-insensitive', () {
      expect(apexOf('SINAR.IAKAUNTAN.COM:443'), 'iakauntan.com');
    });

    test('leaves a host that has no label in front of it alone', () {
      // Never called this way in a browser, but returning `com` here
      // would send the visitor somewhere that is not the platform.
      expect(apexOf('iakauntan.com'), 'iakauntan.com');
      expect(apexOf('localhost'), 'localhost');
    });

    test('keeps everything after the first label', () {
      expect(apexOf('a.b.iakauntan.com'), 'b.iakauntan.com');
    });
  });
}
