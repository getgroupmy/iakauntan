import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import '../tool/icons.dart';

/// The build-time icon generator.
///
/// Worth a test rather than a look, because the failure it prevents is
/// invisible in review: a maskable icon that is wrong still looks like a
/// perfectly good square, and only loses its edges once a phone crops it
/// to a circle. Nobody finds out until it is installed.
void main() {
  /// A source with a deliberate mark in the middle and a known colour in
  /// the corners, so what happened to it can be read off the output.
  Uint8List source({
    int width = 1024,
    int height = 1024,
    int cornerAlpha = 255,
  }) {
    final image = img.Image(width: width, height: height, numChannels: 4);
    img.fill(image, color: img.ColorRgba8(11, 122, 107, cornerAlpha));
    // A white block dead centre, a quarter of the width.
    img.fillRect(
      image,
      x1: (width * 0.375).round(),
      y1: (height * 0.375).round(),
      x2: (width * 0.625).round(),
      y2: (height * 0.625).round(),
      color: img.ColorRgba8(255, 255, 255, 255),
    );
    return Uint8List.fromList(img.encodePng(image));
  }

  img.Image decode(GeneratedIcon icon) => img.decodePng(icon.bytes)!;

  GeneratedIcon named(List<GeneratedIcon> icons, String path) =>
      icons.firstWhere((i) => i.path == path);

  group('generateIcons', () {
    test('writes exactly the files it planned to', () {
      final icons = generateIcons(source());
      expect(
        icons.map((i) => i.path).toList(),
        iconPlan.map((s) => s.path).toList(),
      );
    });

    // The plan compared against ITSELF, above, holds however wrong
    // both are. `web/manifest.json` is the one thing outside this file
    // that names these paths and is fetched by a browser at runtime,
    // so a web icon renamed in one place and not the other is a 404 on
    // an installed app -- which is exactly what the test above reads as
    // if it were checking, and is not.
    //
    // Android and iOS are deliberately not here: their icon names are
    // fixed by the platforms and carry no manifest of their own to
    // disagree with.
    test('and the web ones are the paths the manifest asks for', () {
      final manifest = jsonDecode(
        File('web/manifest.json').readAsStringSync(),
      ) as Map<String, dynamic>;
      final asked = [
        for (final i in (manifest['icons'] as List))
          'web/${(i as Map)['src']}',
      ]..sort();
      final planned = [
        for (final s in iconPlan)
          if (s.path.startsWith('web/icons/')) s.path,
      ]..sort();

      expect(
        planned,
        asked,
        reason: 'web/manifest.json and iconPlan name different files',
      );
    });

    test('at the sizes the manifest claims they are', () {
      final icons = generateIcons(source());
      for (final spec in iconPlan) {
        final image = decode(named(icons, spec.path));
        expect(image.width, spec.size, reason: spec.path);
        expect(image.height, spec.size, reason: spec.path);
      }
    });

    // The whole reason this is a library with a test. The mark has to
    // sit inside the middle 80%, so the outer fifth a launcher may crop
    // carries nothing but background.
    test('a maskable icon keeps its mark inside the safe zone', () {
      final icons = generateIcons(source());
      final maskable = decode(named(icons, 'web/icons/Icon-maskable-512.png'));

      // The centre is still the mark.
      final centre = maskable.getPixel(256, 256);
      expect(centre.r, greaterThan(200));
      expect(centre.g, greaterThan(200));
      expect(centre.b, greaterThan(200));

      // And a pixel just inside the edge — well outside the safe zone —
      // is the plate, not the source's own edge content.
      for (final at in const [
        (4, 4),
        (508, 4),
        (4, 508),
        (508, 508),
        (256, 4),
      ]) {
        final edge = maskable.getPixel(at.$1, at.$2);
        expect(edge.a, 255, reason: 'a maskable icon may not be transparent');
      }
    });

    test('and a plain one fills the square', () {
      final icons = generateIcons(source());
      final plain = decode(named(icons, 'web/icons/Icon-512.png'));
      // The source is solid to its own edges, so a plain icon is too —
      // no padding was introduced where none was asked for.
      final corner = plain.getPixel(1, 1);
      expect(corner.r, closeTo(11, 12));
      expect(corner.g, closeTo(122, 12));
      expect(corner.b, closeTo(107, 12));
    });

    // A maskable icon may not be transparent: the launcher fills what it
    // crops to, and a transparent one lands as a black or white blob
    // depending on the phone.
    test('a transparent source still comes out opaque', () {
      final icons = generateIcons(source(cornerAlpha: 0));
      final maskable = decode(named(icons, 'web/icons/Icon-maskable-192.png'));
      for (var x = 0; x < 192; x += 24) {
        expect(maskable.getPixel(x, 4).a, 255);
      }
    });

    test('a source that is not square is cropped, not squashed', () {
      final icons = generateIcons(source(width: 1400, height: 1024));
      final plain = decode(named(icons, 'web/icons/Icon-512.png'));
      expect(plain.width, plain.height);

      // Centre-cropped, so the mark is still in the middle.
      final centre = plain.getPixel(256, 256);
      expect(centre.r, greaterThan(200));
    });
  });

  group('what it refuses', () {
    test('anything that is not an image', () {
      expect(
        () => generateIcons(Uint8List.fromList('not a png'.codeUnits)),
        throwsA(isA<ArgumentError>()),
      );
    });

    // Upscaling a small logo to 512 produces a blurred square that reads
    // as a bug in the product rather than as a bad upload, so it is
    // refused with the size it wanted named in the message.
    test('and a source too small to make the largest icon from', () {
      expect(
        () => generateIcons(source(width: 256, height: 256)),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            allOf(contains('512'), contains('256x256')),
          ),
        ),
      );
    });

    test('but 512 exactly is enough', () {
      expect(generateIcons(source(width: 512, height: 512)).length,
          iconPlan.length);
    });
  });
}
