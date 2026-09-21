import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../core/router.dart';
import '../../core/theme.dart';
import 'feedback_screen.dart';
import 'file_drop.dart';
import 'screenshot.dart';

/// Where the button sits, as a fraction of the space it can sit in.
///
/// Fractions rather than pixels, so rotating a phone or resizing a
/// window keeps the button roughly where it was put instead of leaving
/// it off the edge. `(1, 1)` is the bottom right, which is where it
/// starts.
typedef ButtonSpot = ({double x, double y});

/// Keeps a spot inside the area it is allowed to be in.
///
/// Pure and separate from the widget so the rule can be asserted. A
/// drag that ends past the edge is the ordinary case, not an error: a
/// finger leaves the screen, and the button has to end up somewhere it
/// can be pressed again.
ButtonSpot clampSpot(ButtonSpot spot) =>
    (x: spot.x.clamp(0.0, 1.0), y: spot.y.clamp(0.0, 1.0));

/// Where the button goes, in pixels, given the room and its own size.
///
/// [inset] keeps it off the very edge — a circle flush against the side
/// of a phone is a circle half under the system's back gesture.
Offset spotToOffset(
  ButtonSpot spot,
  Size room,
  double diameter, {
  double inset = Space.md,
}) {
  // The travel available is the room less the button and both insets.
  // Negative on a window narrower than the button itself, which is why
  // this clamps rather than trusting the subtraction.
  final travelX = (room.width - diameter - inset * 2).clamp(
    0.0,
    double.infinity,
  );
  final travelY = (room.height - diameter - inset * 2).clamp(
    0.0,
    double.infinity,
  );
  final safe = clampSpot(spot);
  return Offset(inset + travelX * safe.x, inset + travelY * safe.y);
}

/// The report button, on every screen, for the people on the beta list.
///
/// Wraps the whole app. The child goes inside a [RepaintBoundary] and
/// the button sits OUTSIDE it as a sibling — which is what keeps the
/// button out of its own screenshots without anything having to be
/// hidden and waited on before the shutter.
///
/// Draws nothing at all for everybody else. `isBetaTesterProvider` is
/// false while it loads and false on an error, so the ordinary app is
/// never waiting on this and a failed lookup costs a button rather than
/// a screen.
class ReportButtonOverlay extends ConsumerStatefulWidget {
  const ReportButtonOverlay({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<ReportButtonOverlay> createState() =>
      _ReportButtonOverlayState();
}

class _ReportButtonOverlayState extends ConsumerState<ReportButtonOverlay> {
  /// The boundary the screenshot is taken from. Holds the app; does not
  /// hold the button.
  final _shot = GlobalKey();

  ButtonSpot _spot = (x: 1, y: 1);

  /// Hidden while the form is open.
  ///
  /// Not because it would be captured — it is outside the boundary — but
  /// because a round button floating over a dialog is a button somebody
  /// presses, and pressing it would open a second copy of the form on
  /// top of the first.
  bool _busy = false;

  static const double _diameter = 52;

  Future<void> _report({required bool withScreenshot}) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final DroppedFile? shot = withScreenshot
          ? await captureScreenshot(_shot)
          : null;
      if (!mounted) return;

      // NOT `context`. This widget lives in `MaterialApp.builder`,
      // whose child is the navigator -- so this widget is ABOVE it, and
      // `Navigator.of(context)` walks upward and throws "Navigator
      // operation requested with a context that does not include a
      // Navigator". Every tap, in production, under a green test suite:
      // the first version of `report_button_test.dart` wrapped the
      // overlay under `home:`, which is below the navigator and is not
      // where the app puts it.
      // `nav.mounted` as well as null, and the analyser is right to
      // insist: `mounted` on this State says nothing about a context
      // fetched from somebody else's key, and the shutter is an await.
      final nav = rootNavigatorKey.currentContext;
      if (nav == null || !nav.mounted) return;

      // A screenshot that could not be taken is worth saying, once,
      // rather than silently opening a form with nothing attached and
      // leaving somebody to wonder where the picture went.
      if (withScreenshot && shot == null) {
        ScaffoldMessenger.of(nav)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            const SnackBar(
              content: Text(
                'The screenshot would not take on this screen — '
                'carry on and attach one yourself.',
              ),
            ),
          );
      }

      await showDialog<void>(
        context: nav,
        // The form is opened HERE, over whatever screen the person was
        // on, rather than by routing to /feedback. That is the whole
        // arrangement: closing it puts them back exactly where they
        // were, in the middle of what they were doing, which is the
        // only way somebody reports the second fault of the morning.
        builder: (_) => ReportDialog(initialFiles: [if (shot != null) shot]),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _menu() {
    // The same reason as in `_report`: this widget is above the
    // navigator that has to hold the sheet.
    final nav = rootNavigatorKey.currentContext;
    if (nav == null) return;
    showModalBottomSheet<void>(
      context: nav,
      showDragHandle: true,
      builder: (sheet) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              key: const ValueKey('report-with-shot'),
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('Take a screenshot and report'),
              subtitle: const Text(
                'This screen as it is now, attached to the report.',
              ),
              onTap: () {
                Navigator.pop(sheet);
                _report(withScreenshot: true);
              },
            ),
            ListTile(
              key: const ValueKey('report-plain'),
              leading: const Icon(Icons.edit_outlined),
              title: const Text('Report without a screenshot'),
              subtitle: const Text('Just tell us what happened.'),
              onTap: () {
                Navigator.pop(sheet);
                _report(withScreenshot: false);
              },
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // `valueOrNull ?? false`: loading and error both mean no button.
    final beta = ref.watch(isBetaTesterProvider).valueOrNull ?? false;
    final boundary = RepaintBoundary(key: _shot, child: widget.child);
    if (!beta) return boundary;

    return Stack(
      children: [
        boundary,
        if (!_busy)
          // `Positioned.fill` around the `LayoutBuilder`, and a second
          // `Stack` inside it. A `Positioned` has to be a DIRECT child
          // of a `Stack` -- with the builder between them Flutter
          // throws "wants to apply ParentData of type StackParentData
          // to a RenderObject set up to accept BoxParentData", which is
          // how this was written first.
          Positioned.fill(
            child: LayoutBuilder(
              builder: (context, box) {
                final where = spotToOffset(
                  _spot,
                  Size(box.maxWidth, box.maxHeight),
                  _diameter,
                );
                return Stack(
                  children: [
                    Positioned(
                      left: where.dx,
                      top: where.dy,
                      child: _Dot(
                        diameter: _diameter,
                        onTap: _menu,
                        onDragged: (delta) => setState(() {
                          // The travel, not the room: moving the
                          // pointer by half the window must move the
                          // button by half the distance it can travel,
                          // or it lags the finger near the edges by its
                          // own width.
                          final travelX =
                              box.maxWidth - _diameter - Space.md * 2;
                          final travelY =
                              box.maxHeight - _diameter - Space.md * 2;
                          _spot = clampSpot((
                            x:
                                _spot.x +
                                (travelX <= 0 ? 0 : delta.dx / travelX),
                            y:
                                _spot.y +
                                (travelY <= 0 ? 0 : delta.dy / travelY),
                          ));
                        }),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
      ],
    );
  }
}

class _Dot extends StatelessWidget {
  const _Dot({
    required this.diameter,
    required this.onTap,
    required this.onDragged,
  });

  final double diameter;
  final VoidCallback onTap;
  final ValueChanged<Offset> onDragged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return GestureDetector(
      // Pan and tap on one detector rather than a Draggable: a
      // Draggable's feedback widget is a second copy of the button
      // lifted out of the tree, and dropping it needs a DragTarget
      // under the whole app. A pan is the same gesture with none of
      // that.
      onPanUpdate: (d) => onDragged(d.delta),
      onTap: onTap,
      child: Semantics(
        button: true,
        label: 'Report a problem with this screen',
        child: Material(
          key: const ValueKey('beta-report-button'),
          color: scheme.errorContainer,
          shape: const CircleBorder(),
          elevation: 6,
          child: SizedBox(
            width: diameter,
            height: diameter,
            child: Icon(
              Icons.bug_report_outlined,
              color: scheme.onErrorContainer,
            ),
          ),
        ),
      ),
    );
  }
}
