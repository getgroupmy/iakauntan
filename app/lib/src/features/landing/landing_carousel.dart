import 'package:flutter/material.dart';

import 'landing_tokens.dart';

/// A page of cards with arrows and dots under it.
///
/// The reference page uses this shape for its product band, and it is
/// the right one there: a grid asks a reader to compare, and a carousel
/// asks them to be shown one thing at a time. For a catalogue somebody
/// scrolls past on the way to the price list, being shown is enough.
///
/// [perPage] is how many cards a page holds at the current width, and
/// the caller works it out — this widget knows nothing about what is on
/// the cards. With everything fitting on one page the arrows and dots
/// are not drawn at all, because a carousel with one page is a grid
/// wearing decoration.
///
/// **No auto-advance.** A band that moves on its own takes the reading
/// position away from somebody halfway through a sentence, and the only
/// way to get it back is to wait for the cycle. The arrows and the dots
/// are the whole interface.
class LandingCarousel extends StatefulWidget {
  const LandingCarousel({
    super.key,
    required this.items,
    required this.perPage,
    required this.height,
    this.onInk = false,
  });

  final List<Widget> items;
  final int perPage;

  /// Fixed, because a PageView cannot size itself to its children and a
  /// band that changes height as it pages reads as a jolt.
  final double height;

  /// Drawn on the dark band, where the controls have to be light.
  final bool onInk;

  @override
  State<LandingCarousel> createState() => _LandingCarouselState();
}

class _LandingCarouselState extends State<LandingCarousel> {
  late final _controller = PageController();
  int _page = 0;

  int get _pages => (widget.items.length / widget.perPage).ceil();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(LandingCarousel old) {
    super.didUpdateWidget(old);
    // The console can shorten the list, or the window can widen and fit
    // more per page, while somebody is looking at the last one.
    if (_page >= _pages && _pages > 0) {
      _page = _pages - 1;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _controller.hasClients) _controller.jumpToPage(_page);
      });
    }
  }

  void _to(int page) {
    if (page < 0 || page >= _pages) return;
    setState(() => _page = page);
    _controller.animateToPage(
      page,
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final onInk = widget.onInk;
    final control = onInk ? Colors.white : scheme.onSurface;

    if (_pages <= 1) {
      return SizedBox(
        height: widget.height,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var i = 0; i < widget.items.length; i++) ...[
              Expanded(child: widget.items[i]),
              if (i < widget.items.length - 1) const SizedBox(width: 16),
            ],
          ],
        ),
      );
    }

    return Column(
      children: [
        SizedBox(
          height: widget.height,
          child: Row(
            children: [
              _Arrow(
                icon: Icons.chevron_left,
                colour: control,
                onTap: _page > 0 ? () => _to(_page - 1) : null,
              ),
              Expanded(
                child: PageView.builder(
                  controller: _controller,
                  onPageChanged: (p) => setState(() => _page = p),
                  itemCount: _pages,
                  itemBuilder: (context, page) {
                    final start = page * widget.perPage;
                    final end =
                        (start + widget.perPage).clamp(0, widget.items.length);
                    final slice = widget.items.sublist(start, end);
                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (var i = 0; i < widget.perPage; i++) ...[
                          // Empty slots on the last page rather than
                          // stretched cards, so a page holding two of
                          // four does not draw two double-width cards.
                          Expanded(
                            child: i < slice.length
                                ? slice[i]
                                : const SizedBox.shrink(),
                          ),
                          if (i < widget.perPage - 1)
                            const SizedBox(width: 16),
                        ],
                      ],
                    );
                  },
                ),
              ),
              _Arrow(
                icon: Icons.chevron_right,
                colour: control,
                onTap: _page < _pages - 1 ? () => _to(_page + 1) : null,
              ),
            ],
          ),
        ),
        const SizedBox(height: Land.gap),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            for (var i = 0; i < _pages; i++)
              Semantics(
                label: 'Page ${i + 1} of $_pages',
                button: true,
                selected: i == _page,
                child: MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: GestureDetector(
                    onTap: () => _to(i),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      margin: const EdgeInsets.symmetric(horizontal: 5),
                      width: i == _page ? 22 : 9,
                      height: 9,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(999),
                        color: i == _page
                            ? (onInk ? Colors.white : scheme.primary)
                            : control.withValues(alpha: 0.3),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }
}

class _Arrow extends StatelessWidget {
  const _Arrow({required this.icon, required this.colour, this.onTap});

  final IconData icon;
  final Color colour;

  /// Null at either end. Drawn faint rather than removed, so the row
  /// does not shift sideways when the first page is reached.
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 44,
      child: IconButton(
        onPressed: onTap,
        icon: Icon(icon),
        iconSize: 28,
        color: colour.withValues(alpha: 0.75),
        disabledColor: colour.withValues(alpha: 0.18),
      ),
    );
  }
}
