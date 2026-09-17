import 'package:flutter/material.dart';

/// The landing page's design tokens.
///
/// The page was assembled with its numbers written where they were
/// used: radii of 10, 12, 14 and 16 within one screen, borders drawn
/// straight from `outlineVariant` in some places and tinted in others,
/// and vertical rhythm chosen per band. Nothing was wrong with any one
/// of them and the whole read as assembled rather than designed, which
/// is what a consistent scale fixes and a nicer colour does not.
///
/// The scale is shadcn/ui's, which is the reference this page is aiming
/// at: one radius with a tighter variant, hairline borders in a low
/// chroma neutral, secondary text a step down in weight rather than in
/// size, and space that grows in a small number of steps rather than
/// continuously.
///
/// **Not a palette.** Every colour here is derived from the theme, and
/// the theme's primary is `brand_colour` from the console. An operator
/// who sets their brand green gets a green page; nothing in this file
/// overrides that, which is the difference between adopting a design
/// language and adopting somebody else's brand.
abstract final class Land {
  /// One radius, and a tighter one for things inside things.
  static const radius = 12.0;
  static const radiusTight = 8.0;
  static const radiusLarge = 16.0;

  /// The vertical rhythm of the page, in four steps.
  ///
  /// A band is [bandY] from the one above it. Inside a band, the
  /// heading block is [gapLg] from the content, cards are [gap] apart,
  /// and lines within a card are [gapSm].
  static const bandY = 88.0;
  static const bandYTight = 64.0;
  static const gapLg = 32.0;
  static const gap = 20.0;
  static const gapSm = 8.0;

  /// The page's measure. Wider than the old 1080 because a three-column
  /// grid at 1080 gives cards too narrow to hold a sentence, and
  /// narrower than the screen because a line of text 1900 pixels long
  /// is a line nobody finishes.
  static const maxWidth = 1200.0;

  /// Where the page stops being a desktop and starts being a phone.
  ///
  /// The masthead folds its links into a menu here and the hero band
  /// changes height, and `0321` lets the console switch each way-in
  /// button on either side of it — so the number is named once rather
  /// than written out at each of the places that has to agree with the
  /// others.
  static const wide = 760.0;
  static const gutter = 24.0;

  /// A hairline, not a rule.
  ///
  /// `outlineVariant` is drawn for dividers and reads heavy at card
  /// scale where there are twenty of them. This is the same colour at
  /// the weight a border wants.
  static Color border(ColorScheme s) => s.outlineVariant.withValues(alpha: 0.6);

  /// The border a card takes when the pointer is over it.
  static Color borderHover(ColorScheme s) => s.primary.withValues(alpha: 0.5);

  /// Secondary text. A step down in colour, not in size: a 12-point
  /// paragraph is a paragraph nobody reads, and the hierarchy is
  /// carried by weight and colour instead.
  static Color muted(ColorScheme s) => s.onSurfaceVariant;

  /// Almost nothing. Depth on this page comes from the border and the
  /// band behind it; a card that floats reads as a dialog.
  static List<BoxShadow> lift(ColorScheme s, {bool hovered = false}) => [
    BoxShadow(
      color: s.shadow.withValues(alpha: hovered ? 0.07 : 0.03),
      blurRadius: hovered ? 16 : 6,
      offset: Offset(0, hovered ? 4 : 2),
    ),
  ];

  /// Headline type. Tight tracking, because a display size set at the
  /// default tracking of a text face reads loose.
  static TextStyle display(ColorScheme s) => TextStyle(
    fontSize: 46,
    height: 1.08,
    fontWeight: FontWeight.w800,
    letterSpacing: -1.4,
    color: s.onSurface,
  );

  static TextStyle heading(ColorScheme s) => TextStyle(
    fontSize: 30,
    height: 1.15,
    fontWeight: FontWeight.w800,
    letterSpacing: -0.8,
    color: s.onSurface,
  );

  static TextStyle cardTitle(ColorScheme s) => TextStyle(
    fontSize: 17,
    height: 1.3,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.2,
    color: s.onSurface,
  );

  static TextStyle body(ColorScheme s) =>
      TextStyle(fontSize: 15, height: 1.6, color: muted(s));

  static TextStyle small(ColorScheme s) =>
      TextStyle(fontSize: 13, height: 1.7, color: muted(s));
}

/// The small capitalised line above a heading.
///
/// shadcn's Badge, and the most recognisable single element of the
/// look this page is aiming at: it tells a reader what kind of section
/// they have arrived at before they have read the heading.
class LandingKicker extends StatelessWidget {
  const LandingKicker(this.label, {super.key, this.icon});

  final String label;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        color: scheme.primary.withValues(alpha: 0.08),
        border: Border.all(color: scheme.primary.withValues(alpha: 0.18)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 13, color: scheme.primary),
            const SizedBox(width: 6),
          ],
          Text(
            label.toUpperCase(),
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.9,
              color: scheme.primary,
            ),
          ),
        ],
      ),
    );
  }
}

/// Kicker, heading, and a line under it — the same three parts in the
/// same order at the top of every band.
///
/// Written once because the alternative is five bands whose headings
/// are 22, 24 and 26 point and sit at three different distances from
/// what follows, which is exactly how the page read before.
class LandingSectionHeader extends StatelessWidget {
  const LandingSectionHeader({
    super.key,
    required this.kicker,
    required this.title,
    this.subtitle,
    this.centred = false,
  });

  final String kicker;
  final String title;
  final String? subtitle;
  final bool centred;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: centred
          ? CrossAxisAlignment.center
          : CrossAxisAlignment.start,
      children: [
        LandingKicker(kicker),
        const SizedBox(height: Land.gap),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: Text(
            title,
            textAlign: centred ? TextAlign.center : TextAlign.start,
            style: Land.heading(scheme),
          ),
        ),
        if (subtitle != null) ...[
          const SizedBox(height: 12),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: Text(
              subtitle!,
              textAlign: centred ? TextAlign.center : TextAlign.start,
              style: Land.body(scheme),
            ),
          ),
        ],
      ],
    );
  }
}
