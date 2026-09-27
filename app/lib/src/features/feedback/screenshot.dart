import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import 'file_drop.dart';

/// The screen, as a PNG, for a bug report to carry.
///
/// ## Why a boundary and a key rather than a plugin
///
/// A platform screenshot needs a permission on Android, a picker on
/// iOS, and does not exist on the web. What this app needs is narrower
/// than a screenshot of the device: it is a picture of ITS OWN window,
/// which Flutter can already produce, on every surface, with nothing
/// asked of anybody.
///
/// The cost is that only what is inside the boundary is captured. That
/// is a feature here — the report button itself is deliberately OUTSIDE
/// it, so it never appears in the picture a tester sends, and nothing
/// has to be hidden and waited on before the shutter.
///
/// ## What it does not capture
///
/// A platform view — a real map, a real webview, a video surface —
/// comes out blank or black. This is a limitation of rendering the
/// layer tree rather than the device framebuffer, and it cannot be
/// worked around from here. It is worth knowing rather than worth
/// fixing: the screens where somebody reports a fault are made of
/// widgets, and a black rectangle where a map was is still a picture of
/// the fault beside it.
///
/// Dialogs and other overlay entries are in a separate layer above the
/// navigator, so a screenshot taken while a dialog is open shows the
/// screen WITHOUT it. Nothing takes one in that state today; the
/// floating button is the only caller and it shoots before it opens
/// anything.

/// Two, which is a retina screen and enough to read a figure in.
///
/// Not [FlutterView.devicePixelRatio]. A desktop at 1 would give a
/// picture too coarse to read the column that was wrong, and a phone at
/// 4 would give a twelve-megabyte PNG that `0660` then refuses at ten.
const double screenshotPixelRatio = 2.0;

/// The file name a screenshot arrives under.
///
/// Stamped, because a tester reporting three faults in a minute would
/// otherwise send three files called the same thing and have to open
/// each to tell them apart. Padded, so the names sort.
String screenshotName(DateTime at) {
  String two(int n) => n.toString().padLeft(2, '0');
  return 'screen-${at.year}${two(at.month)}${two(at.day)}'
      '-${two(at.hour)}${two(at.minute)}${two(at.second)}.png';
}

/// PNG bytes, wrapped as the file a report will carry.
///
/// Split from [captureScreenshot] so this half can be asserted. The
/// other half rasterises, which a headless `flutter test` does not do
/// dependably -- `toImage` there fails for reasons that are about the
/// harness rather than about this code, and a test that swallowed that
/// would be asserting the harness.
///
/// What IS worth asserting lives here: the name, and the type. The type
/// decides what the storage object is served as and which thumbnail the
/// picker draws, and a mutant that dropped it survived an earlier
/// version of these tests -- which is how this function came to exist.
DroppedFile screenshotFile(Uint8List png, {DateTime? at}) => DroppedFile(
  name: screenshotName(at ?? DateTime.now()),
  bytes: png,
  mimeType: 'image/png',
);

/// Captures what [key]'s boundary is drawing, or null if it cannot.
///
/// Null rather than a throw, and the caller carries on without the
/// picture. A tester who pressed "screenshot and report" on a screen
/// that would not capture still has something to say, and taking the
/// form away from them because the camera failed is the wrong trade —
/// the sentence was always the valuable half.
Future<DroppedFile?> captureScreenshot(
  GlobalKey key, {
  double pixelRatio = screenshotPixelRatio,
  DateTime? at,
}) async {
  final object = key.currentContext?.findRenderObject();
  if (object is! RenderRepaintBoundary) return null;

  // A boundary that has never been laid out, or is mid-layout, throws
  // rather than returning an empty image. Reached when the button is
  // pressed during the first frame.
  if (object.debugNeedsPaint) return null;

  final ui.Image image;
  try {
    image = await object.toImage(pixelRatio: pixelRatio);
  } catch (_) {
    // The one broad catch in this file, and deliberate: `toImage` fails
    // for reasons that are all about the platform rather than about
    // this app -- no GL context, a surface the web renderer will not
    // read back, a window with no size yet -- and every one of them has
    // the same right answer, which is to report without a picture.
    return null;
  }

  try {
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    if (data == null) return null;
    return screenshotFile(data.buffer.asUint8List(), at: at);
  } finally {
    // The image holds native memory that is not the garbage
    // collector's to free. Missing this leaks a full-resolution bitmap
    // per screenshot, on a feature whose whole point is being used
    // often.
    image.dispose();
  }
}
