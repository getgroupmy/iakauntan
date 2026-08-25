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
  // Made on the first build that needs one, not on the first access.
  // Somebody who has asked their system to reduce motion never takes
  // the animated branch at all, so they never pay for a ticker — and,
  // when the page goes away, `dispose` must not be the thing that
  // creates one: building an AnimationController needs to look up
  // TickerMode, and by dispose the element is deactivated, which
  // throws. That is what a `late final` field did here.
  AnimationController? _c;
  bool _started = false;

  AnimationController _controller() => _c ??= AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 420),
  );

  @override
  void dispose() {
    _c?.dispose();
    super.dispose();
  }

  void _startWhenVisible(double fractionVisible) {
    if (_started || fractionVisible <= 0) return;
    _started = true;
    Future<void>.delayed(widget.delay, () {
      if (mounted) _c?.forward();
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

    final c = _controller();
    return _VisibilityProbe(
      onVisible: _startWhenVisible,
      child: AnimatedBuilder(
        animation: c,
        builder: (context, child) {
          final t = Curves.easeOutCubic.transform(c.value);
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
  /// The scroll position of the enclosing viewport.
  ///
  /// This used to be a `NotificationListener<ScrollNotification>`
  /// wrapped around the child, and that never fired once. Notifications
  /// travel **up** the tree from the `Scrollable` that dispatches them,
  /// and every one of these probes is a descendant of the page's scroll
  /// view — so the listener sat below the sender and heard nothing.
  ///
  /// The only thing that ever revealed anything was the post-frame
  /// check in `initState`, which is true exactly for what is on screen
  /// at the first frame. Everything below the fold stayed at opacity
  /// zero permanently: laid out, taking its full height, and invisible.
  /// On a phone, where the hero fills the screen, that was the entire
  /// page under a blank gap the size of the content that should have
  /// been in it.
  ///
  /// A `ScrollPosition` is a `Listenable` and `Scrollable.maybeOf`
  /// finds it from a descendant, which is the direction that actually
  /// works.
  ScrollPosition? _position;

  @override
  void initState() {
    super.initState();
    // Everything above the fold is visible before a single scroll
    // happens, so it has to be checked once on arrival or the hero
    // never appears.
    WidgetsBinding.instance.addPostFrameCallback((_) => _check());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final next = Scrollable.maybeOf(context)?.position;
    if (identical(next, _position)) return;
    _position?.removeListener(_check);
    _position = next;
    _position?.addListener(_check);
    // Nothing to scroll — a preview pane, a test, a page short enough
    // to fit. Reveal rather than wait for an event that cannot come:
    // invisible forever is a far worse failure than un-animated.
    if (next == null) widget.onVisible(1);
  }

  @override
  void dispose() {
    _position?.removeListener(_check);
    super.dispose();
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
  Widget build(BuildContext context) => widget.child;
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

  /// Same correction as `_VisibilityProbe`: this was a
  /// `NotificationListener<ScrollNotification>` around the child, which
  /// is below the `Scrollable` that sends them and therefore never
  /// heard one. The element simply never moved.
  ScrollPosition? _position;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final next = Scrollable.maybeOf(context)?.position;
    if (identical(next, _position)) return;
    _position?.removeListener(_onScroll);
    _position = next;
    _position?.addListener(_onScroll);
  }

  @override
  void dispose() {
    _position?.removeListener(_onScroll);
    super.dispose();
  }

  void _onScroll() {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    final y = box.localToGlobal(Offset.zero).dy;
    _anchor ??= y + _offset;

    final travelled = _anchor! - y;
    final next = (travelled * widget.factor)
        .clamp(-widget.maxOffset, widget.maxOffset);
    if ((next - _offset).abs() > 0.5) setState(() => _offset = next);
  }

  @override
  Widget build(BuildContext context) {
    // Motion is a preference. Somebody who has asked their system to
    // reduce it gets the element where the layout put it.
    if (MediaQuery.maybeOf(context)?.disableAnimations ?? false) {
      return widget.child;
    }
    return Transform.translate(
      offset: Offset(0, _offset),
      child: widget.child,
    );
  }
}

/// Count a figure up to itself when it scrolls into view.
///
/// The band of numbers on a page like this conventionally animates, and
/// the reason is not decoration: a figure that arrives at rest is read
/// as a label, and one that counts up is read as a measurement.
///
/// [text] is whatever the console typed — "240,000", "1,200+", "RM4b".
/// The digits inside it are found and scaled together; everything that
/// is not a digit is left exactly where it was, so a currency prefix, a
/// thousands separator and a trailing plus all survive. A value with no
/// digits at all is simply drawn, which is the correct behaviour for a
/// figure somebody wrote as a word.
///
/// Once, like [RevealOnScroll], and not at all for a viewer who has
/// asked their system to reduce motion — for whom the final value is
/// the only honest thing to show.
class CountUp extends StatefulWidget {
  const CountUp(this.text, {super.key, this.style, this.duration});

  final String text;
  final TextStyle? style;
  final Duration? duration;

  @override
  State<CountUp> createState() => _CountUpState();
}

class _CountUpState extends State<CountUp>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: widget.duration ?? const Duration(milliseconds: 1100),
  );
  bool _started = false;

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  /// The value at [t], with every run of digits scaled and re-padded to
  /// the width it will finish at — so "240,000" does not shuffle left
  /// and right as it climbs, which reads as a glitch rather than as a
  /// count.
  String _at(double t) => widget.text.replaceAllMapped(RegExp(r'\d+'), (m) {
    final full = m[0]!;
    final scaled = (int.parse(full) * t).round().toString();
    return scaled.padLeft(full.length, '0');
  });

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.maybeOf(context)?.disableAnimations ?? false) {
      return Text(widget.text, style: widget.style);
    }
    return _VisibilityProbe(
      onVisible: (fraction) {
        if (_started || fraction <= 0) return;
        _started = true;
        _c.forward();
      },
      child: AnimatedBuilder(
        animation: _c,
        builder: (context, _) => Text(
          _at(Curves.easeOutCubic.transform(_c.value)),
          style: widget.style,
        ),
      ),
    );
  }
}
