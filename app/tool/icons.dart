/// Turning one square image into the icon set a browser wants.
///
/// Build-time only. Nothing here ships in the bundle — `make_icons.dart`
/// runs this before `flutter build web`, writing over the five PNGs in
/// `web/`, and the built output is what a visitor gets. That is the whole
/// reason the console's branding tab says an uploaded icon takes effect
/// on the next deploy rather than on save.
///
/// A library rather than everything inside `main()` so the sizes and the
/// padding can be asserted without running a build. Getting a maskable
/// icon wrong is invisible in review — it looks fine as a square and
/// loses its edges once Android masks it to a circle — so it is exactly
/// the arithmetic worth having a test for.
library;

import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// One file to write, named as it is named in `web/`.
class GeneratedIcon {
  const GeneratedIcon(this.path, this.bytes, {required this.maskable});

  /// Relative to `web/`, so the caller does not have to know the layout.
  final String path;
  final Uint8List bytes;
  final bool maskable;
}

/// The five files `web/manifest.json` and `web/index.html` already name.
///
/// Fixed, not derived: the manifest lists these paths and these sizes,
/// and generating a sixth nothing references would be a file nobody
/// fetches. Change one here and change it there.
const iconPlan = <({String path, int size, bool maskable})>[
  (path: 'favicon.png', size: 32, maskable: false),
  (path: 'icons/Icon-192.png', size: 192, maskable: false),
  (path: 'icons/Icon-512.png', size: 512, maskable: false),
  (path: 'icons/Icon-maskable-192.png', size: 192, maskable: true),
  (path: 'icons/Icon-maskable-512.png', size: 512, maskable: true),
];

/// How much of a maskable icon the mark may occupy.
///
/// The spec reserves the outer fifth: a launcher may crop a maskable
/// icon to a circle, a squircle or a rounded square, and only the middle
/// 80% is guaranteed to survive all of them. A full-bleed mark rendered
/// straight into a maskable slot loses its corners on Android and nobody
/// finds out until it is installed.
const maskableSafeFraction = 0.8;

/// The icon set, from one square source.
///
/// Throws [ArgumentError] on anything that is not a decodable image, and
/// on a source too small to make the largest icon from — upscaling a
/// 64px logo to 512 produces a blurred square that looks like a bug in
/// the product rather than a bad upload, so it is refused with a message
/// naming the size it needed.
List<GeneratedIcon> generateIcons(Uint8List source) {
  final decoded = img.decodeImage(source);
  if (decoded == null) {
    throw ArgumentError('That file could not be read as an image.');
  }

  final shortest = decoded.width < decoded.height
      ? decoded.width
      : decoded.height;
  if (shortest < 512) {
    throw ArgumentError(
      'An app icon has to be at least 512x512. This one is '
      '${decoded.width}x${decoded.height}.',
    );
  }

  // Square first, from the middle, so a source that is nearly square is
  // trimmed rather than squashed. A stretched logo is worse than a
  // cropped one, and the console asks for a square.
  final square = decoded.width == decoded.height
      ? decoded
      : img.copyCrop(
          decoded,
          x: (decoded.width - shortest) ~/ 2,
          y: (decoded.height - shortest) ~/ 2,
          width: shortest,
          height: shortest,
        );

  final plate = _plateColour(square);

  return [
    for (final spec in iconPlan)
      GeneratedIcon(
        spec.path,
        Uint8List.fromList(img.encodePng(
          spec.maskable
              ? _maskable(square, spec.size, plate)
              : img.copyResize(
                  square,
                  width: spec.size,
                  height: spec.size,
                  interpolation: img.Interpolation.cubic,
                ),
        )),
        maskable: spec.maskable,
      ),
  ];
}

/// The mark inside the safe zone, on an opaque plate.
///
/// Padding rather than filling, and it costs something: a source that
/// already carries its own margin comes out slightly smaller than it
/// could be. That is the right trade — a mark that is a little small in
/// a circle is a cosmetic complaint, and a mark whose edges are shaved
/// off is a broken icon.
img.Image _maskable(img.Image square, int size, img.Color plate) {
  final inner = (size * maskableSafeFraction).round();
  final offset = (size - inner) ~/ 2;

  final canvas = img.Image(width: size, height: size, numChannels: 4);
  img.fill(canvas, color: plate);
  img.compositeImage(
    canvas,
    img.copyResize(
      square,
      width: inner,
      height: inner,
      interpolation: img.Interpolation.cubic,
    ),
    dstX: offset,
    dstY: offset,
  );
  return canvas;
}

/// What to put behind a maskable icon.
///
/// A maskable icon may not be transparent — the launcher fills what it
/// crops to, and a transparent one comes out as a black or white blob
/// depending on the phone. So the corner pixel is used, which is the
/// background of any icon drawn as a mark on a field; and where that
/// pixel is itself transparent, white, because a logo designed on
/// transparency was almost certainly drawn to sit on paper.
img.Color _plateColour(img.Image square) {
  final corner = square.getPixel(0, 0);
  if (corner.a < 250) {
    return img.ColorRgba8(255, 255, 255, 255);
  }
  return img.ColorRgba8(
    corner.r.toInt(),
    corner.g.toInt(),
    corner.b.toInt(),
    255,
  );
}
