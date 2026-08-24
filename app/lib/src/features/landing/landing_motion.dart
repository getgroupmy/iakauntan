import 'package:flutter/material.dart';

/// Fade a thing in and lift it a little as it scrolls into view.
///
/// Deliberately once. A section that re-animates every time it passes
/// the fold is a section somebody has to wait for twice, and on a page
/// people scroll up and down while deciding, that reads as jitter
/// rather than polish.
///
/// [delay] staggers siblings so a row of cards arrives as a row rather
/// than all at once. Kept small: a landing page that makes somebody wait
/// to read it has mistaken motion for interest.
class RevealOnScroll extends StatefulWidget {
  const RevealOnScroll({
    super.key,
    required this.child,
    this.delay = Duration.zero,
  });

  final Widget child;
  final Duration delay;

  @override
  State<RevealOnScroll> createState() => _RevealOnScrollState();
}

class _RevealOnScrollState extends State<RevealOnScroll>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 420),
  );
  bool _started = false;

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  void _startWhenVisible(double fractionVisible) {
    if (_started || fractionVisible <= 0) return;
    _started = true;
    Future<void>.delayed(widget.delay, () {
      if (mounted) _c.forward();
    });
  }

  @override
  Widget build(BuildContext context) {
    // Motion is a preference, not a decoration: somebody who has asked
    // their system to reduce it gets the content and none of the
    // movement.
    if (MediaQuery.maybeOf(context)?.disableAnimations ?? false) {
      return widget.child;
    }

    return _VisibilityProbe(
      onVisible: _startWhenVisible,
      child: AnimatedBuilder(
        animation: _c,
        builder: (context, child) {
          final t = Curves.easeOutCubic.transform(_c.value);
          return Opacity(
            opacity: t,
            child: Transform.translate(
              offset: Offset(0, (1 - t) * 18),
              child: child,
            ),
          );
        },
        child: widget.child,
      ),
    );
  }
}

/// Tells its child when it has come into the viewport.
///
/// Written rather than pulled in, because one scroll notification is a
/// smaller thing to own than a dependency, and the page it serves has
/// to load for somebody who has not signed in.
class _VisibilityProbe extends StatefulWidget {
  const _VisibilityProbe({required this.child, required this.onVisible});

  final Widget child;
  final void Function(double fractionVisible) onVisible;

  @override
  State<_VisibilityProbe> createState() => _VisibilityProbeState();
}

class _VisibilityProbeState extends State<_VisibilityProbe> {
  @override
  void initState() {
    super.initState();
    // Everything above the fold is visible before a single scroll
    // notification fires, so it has to be checked once on arrival or the
    // hero never appears.
    WidgetsBinding.instance.addPostFrameCallback((_) => _check());
  }

  void _check() {
    if (!mounted) return;
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    final top = box.localToGlobal(Offset.zero).dy;
    final height = MediaQuery.sizeOf(context).height;
    // A tenth of the way up from the bottom, so a card starts arriving
    // as its first line appears rather than once it is fully past.
    if (top < height * 0.92) widget.onVisible(1);
  }

  @override
  Widget build(BuildContext context) {
    return NotificationListener<ScrollNotification>(
      onNotification: (_) {
        _check();
        // False: this is watching, not consuming. Returning true would
        // stop the notification reaching the scroll view above and the
        // page would not scroll at all.
        return false;
      },
      child: widget.child,
    );
  }
}

/// A card that lifts under the pointer.
///
/// The affordance is the point rather than the shadow: on a page whose
/// job is to be explored, a thing that responds is a thing somebody
/// tries.
class HoverLift extends StatefulWidget {
  const HoverLift({super.key, required this.builder, this.onTap});

  final Widget Function(BuildContext context, bool hovered) builder;
  final VoidCallback? onTap;

  @override
  State<HoverLift> createState() => _HoverLiftState();
}

class _HoverLiftState extends State<HoverLift> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: widget.onTap == null
          ? SystemMouseCursors.basic
          : SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOut,
          transform: Matrix4.translationValues(0, _hovered ? -3 : 0, 0),
          child: widget.builder(context, _hovered),
        ),
      ),
    );
  }
}

/// Move a thing at a fraction of the scroll speed.
///
/// The depth effect a scrolling marketing page gets from parallax, done
/// with the scroll position Flutter already has rather than a library
/// that drives DOM transforms — there are no DOM nodes here to drive.
///
/// [factor] is how far it moves against the page: 0 is pinned to the
/// content, 1 would be a second scroll view. Small numbers only. Past
/// about 0.15 the element visibly disagrees with the text beside it,
/// which reads as a rendering fault rather than as depth.
///
/// Clamped, so an element near the top of a long page cannot be dragged
/// out of its own band by a large scroll offset.
class Parallax extends StatefulWidget {
  const Parallax({
    super.key,
    required this.child,
    this.factor = 0.08,
    this.maxOffset = 40,
  });

  final Widget child;
  final double factor;

  /// The furthest it will travel, in logical pixels, either way.
  final double maxOffset;

  @override
  State<Parallax> createState() => _ParallaxState();
}

class _ParallaxState extends State<Parallax> {
  double _offset = 0;

  /// Where this widget sat when the page had not been scrolled, so the
  /// displacement is measured from its own position rather than from
  /// the top of the document. Without it every element below the fold
  /// starts already displaced.
  double? _anchor;

  bool _onScroll(ScrollNotification n) {
    if (n.metrics.axis != Axis.vertical) return false;
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return false;
    final y = box.localToGlobal(Offset.zero).dy;
    _anchor ??= y + _offset;

    final travelled = (_anchor! - y);
    final next = (travelled * widget.factor)
        .clamp(-widget.maxOffset, widget.maxOffset);
    if ((next - _offset).abs() > 0.5) setState(() => _offset = next);
    return false;
  }

  @override
  Widget build(BuildContext context) {
    // Motion is a preference. Somebody who has asked their system to
    // reduce it gets the element where the layout put it.
    if (MediaQuery.maybeOf(context)?.disableAnimations ?? false) {
      return widget.child;
    }
    return NotificationListener<ScrollNotification>(
      onNotification: _onScroll,
      child: Transform.translate(
        offset: Offset(0, _offset),
        child: widget.child,
      ),
    );
  }
}
