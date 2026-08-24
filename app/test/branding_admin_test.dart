import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/features/admin/branding_admin.dart';

/// The branding tab.
///
/// Most of it is a form, and a form is asserted by looking at it. What
/// is worth a test is the part with a rule behind it: which content
/// types may reach a public bucket, and that the scheme preview draws
/// something for any seed it is handed — including the seeds that are
/// the reason the preview exists.
void main() {
  group('mimeForExtension', () {
    test('the three the bucket accepts', () {
      expect(mimeForExtension('png'), 'image/png');
      expect(mimeForExtension('jpg'), 'image/jpeg');
      expect(mimeForExtension('jpeg'), 'image/jpeg');
      expect(mimeForExtension('webp'), 'image/webp');
    });

    test('and it does not care how they were typed', () {
      expect(mimeForExtension('PNG'), 'image/png');
      expect(mimeForExtension('JPEG'), 'image/jpeg');
    });

    // The one that matters. `0161` narrowed the bucket to three types
    // because Storage serves an object back under the type it was
    // stored with, and an SVG is the one image format that is also a
    // program — a stable public URL on the project's own hostname
    // serving attacker-controlled markup is a phishing page for this
    // product's sign-in screen. Storage refuses it either way; this
    // refuses it a step earlier.
    test('an SVG is not an image as far as this is concerned', () {
      expect(mimeForExtension('svg'), isNull);
      expect(mimeForExtension('SVG'), isNull);
    });

    test('and neither is anything else', () {
      expect(mimeForExtension('html'), isNull);
      expect(mimeForExtension('pdf'), isNull);
      expect(mimeForExtension(''), isNull);
      expect(mimeForExtension(null), isNull);
    });
  });

  group('SchemePreview', () {
    Future<void> pump(WidgetTester tester, Color seed, Brightness b) =>
        tester.pumpWidget(MaterialApp(
          home: Scaffold(
            body: SchemePreview(seed: seed, brightness: b),
          ),
        ));

    testWidgets('draws every role of the scheme, both ways', (tester) async {
      for (final brightness in Brightness.values) {
        await pump(tester, const Color(0xFF0B7A6B), brightness);
        for (final role in [
          'Primary',
          'Container',
          'Secondary',
          'Surface',
          'Surface tint',
          'Error',
        ]) {
          expect(find.text(role), findsOneWidget,
              reason: '$role should be shown in $brightness');
        }
        // The two controls, in the colours they will actually be.
        expect(find.text('Post'), findsOneWidget);
        expect(find.text('Cancel'), findsOneWidget);
      }
    });

    testWidgets('says which brightness it is showing', (tester) async {
      await pump(tester, const Color(0xFF0B7A6B), Brightness.light);
      expect(find.text('Light'), findsOneWidget);
      await pump(tester, const Color(0xFF0B7A6B), Brightness.dark);
      expect(find.text('Dark'), findsOneWidget);
    });

    // The seeds somebody actually picks, including the two that break
    // naive schemes: pure black and pure white have no hue to derive
    // from, and a preview that throws on them is a console that cannot
    // show you why not to use them.
    testWidgets('survives the awkward seeds', (tester) async {
      for (final seed in const [
        Color(0xFF000000),
        Color(0xFFFFFFFF),
        Color(0xFFFF0000),
        Color(0xFF0F172A),
      ]) {
        for (final brightness in Brightness.values) {
          await pump(tester, seed, brightness);
          expect(tester.takeException(), isNull);
          expect(find.text('Primary'), findsOneWidget);
        }
      }
    });
  });
}
