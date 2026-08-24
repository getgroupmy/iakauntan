import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/safe_link.dart';
import 'landing_content.dart';
import 'landing_dark_band.dart';
import 'landing_motion.dart';
import 'landing_pricing.dart';
import 'landing_tokens.dart';

/// The corporate landing page.
///
/// What somebody sees when they type the address on a business card:
/// what this is, what it does, a way in, and the app on their phone.
/// Everything on it except the layout comes from the database, so a
/// platform administrator can change the copy without a deployment.
class LandingScreen extends ConsumerWidget {
  const LandingScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final fetched = ref.watch(landingContentProvider);
    // While it loads, and if it fails, show the built-in copy rather
    // than a spinner or an error: the sign-in button is on this page and
    // somebody may be trying to reach their books.
    return Scaffold(
      body: SafeArea(
        child: LandingPage(
          content: fetched.valueOrNull ?? LandingContent.fallback,
        ),
      ),
    );
  }
}

/// The page itself, given its content.
///
/// Split from [LandingScreen] so the console can draw the same widgets
/// against `platform_landing_preview` — the draft. A preview built from
/// a second set of widgets would drift from the page it claims to
/// preview, and a preview that drifts is worse than none because it is
/// believed. One payload, one parser, one set of widgets.
class LandingPage extends StatelessWidget {
  const LandingPage({super.key, required this.content, this.preview = false});

  final LandingContent content;

  /// Drawn inside the console rather than at the front door.
  ///
  /// The only difference is that the ways in do nothing: a platform
  /// administrator checking their copy should not be thrown to the
  /// sign-in screen by tapping the button they are looking at.
  final bool preview;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    // Anchors for the masthead's links. A landing page whose navigation
    // points at pages that do not exist is worse than one with no
    // navigation, so these scroll to bands on this page and there is a
    // key only where there is a band.
    final features = GlobalKey();
    final why = GlobalKey();
    final pricing = GlobalKey();
    final apps = GlobalKey();

    return Container(
      color: scheme.surface,
      child: Column(
        children: [
          // Pinned rather than scrolled away with the hero. The way
          // in is the point of this page and it should not require
          // scrolling back to the top to find.
          _Masthead(
            content: content,
            preview: preview,
            anchors: {
              'Features': features,
              if (content.reasons.isNotEmpty) 'Why us': why,
              if (content.showPricing && content.modules.isNotEmpty)
                'Pricing': pricing,
              if (content.appLinks.isNotEmpty) 'Apps': apps,
            },
          ),
          Expanded(
            child: SingleChildScrollView(
              child: Column(
                children: [
                  _Band(
                    child: RevealOnScroll(
                      child: _Hero(content: content, preview: preview),
                    ),
                  ),
                  // Directly under the hero, answering the first
                  // question anybody asks of accounting software here.
                  if (content.badges.isNotEmpty)
                    _Band(
                      tinted: true,
                      tight: true,
                      child: _Badges(badges: content.badges),
                    ),
                  if (content.sections.isNotEmpty)
                    _Band(
                      key: features,
                      child: _Sections(sections: content.sections),
                    ),
                  // Somewhere to press, for a visitor who has read
                  // the feature panel and does not need the rest.
                  if (content.ctaHeadline != null)
                    _Band(
                      child: RevealOnScroll(
                        child: _Cta(content: content, preview: preview),
                      ),
                    ),
                  if (content.reasons.isNotEmpty)
                    _Band(
                      key: why,
                      tinted: true,
                      child: _Reasons(reasons: content.reasons),
                    ),
                  // The three that ship empty. Each renders nothing
                  // at all until an operator has written rows, which
                  // is the correct page for a platform that has not
                  // made a claim rather than a gap to fill with
                  // invented ones.
                  // The catalogue, on its own dark band.
                  //
                  // Present only when `show_pricing` is on, because
                  // that is what `app.landing_payload` gates `modules`
                  // behind. Arguably the names of what is for sale and
                  // the prices of it are two decisions rather than one,
                  // but they are one today and this band does not get
                  // to route around an operator's switch.
                  if (content.modules.isNotEmpty)
                    LandingDarkBand(modules: content.modules),
                  if (content.stats.isNotEmpty)
                    _Band(
                      child: RevealOnScroll(
                        child: _Stats(stats: content.stats),
                      ),
                    ),
                  if (content.testimonials.isNotEmpty)
                    _Band(
                      tinted: true,
                      child: _Testimonials(
                        testimonials: content.testimonials,
                      ),
                    ),
                  if (content.logos.isNotEmpty)
                    _Band(
                      tight: true,
                      child: RevealOnScroll(
                        child: _Logos(logos: content.logos),
                      ),
                    ),
                  if (content.showPricing && content.modules.isNotEmpty)
                    _Band(
                      key: pricing,
                      tinted: true,
                      child: RevealOnScroll(
                        delay: const Duration(milliseconds: 60),
                        child: LandingPricing(content: content),
                      ),
                    ),
                  if (content.appLinks.isNotEmpty)
                    _Band(
                      key: apps,
                      child: RevealOnScroll(
                        child: _AppLinks(
                          links: content.appLinks,
                          preview: preview,
                        ),
                      ),
                    ),
                  _Footer(content: content, preview: preview),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// One full-width band, with the page's content centred inside it.
///
/// The page used to be a single column inside one padded box, which
/// made every section the same width as every other and left the
/// tinted bands nowhere to go. Bands run edge to edge and the content
/// inside them does not, which is the whole difference between a page
/// that reads as sections and a page that reads as a list.
class _Band extends StatelessWidget {
  const _Band({
    super.key,
    required this.child,
    this.tinted = false,
    this.tight = false,
  });

  final Widget child;

  /// Whether this band sits on the faint grey that separates it from
  /// the ones either side. Alternating rather than every other one by
  /// index, because which bands render at all depends on what the
  /// operator has written.
  final bool tinted;

  /// Bands that carry one row rather than a grid — the logo wall, the
  /// store buttons — get the shorter rhythm, or the page grows a hole
  /// around them.
  final bool tight;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      color: tinted ? scheme.surfaceContainerLowest : scheme.surface,
      padding: EdgeInsets.symmetric(
        horizontal: Land.gutter,
        vertical: tight ? Land.bandYTight : Land.bandY,
      ),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: Land.maxWidth),
          child: child,
        ),
      ),
    );
  }
}

/// The bar across the top, pinned.
///
/// The logo on the left, links to the bands that exist on this page in
/// the middle, and the way in on the right. Left as a plain row rather
/// than given drop-down menus: a menu whose items are the four headings
/// already visible below it is a menu that costs a tap and saves
/// nothing, and this product has no other pages to point one at.
class _Masthead extends StatelessWidget {
  const _Masthead({
    required this.content,
    required this.anchors,
    this.preview = false,
  });

  final LandingContent content;

  /// In the console the ways in are shown and do nothing. The anchors
  /// still work — scrolling the preview is the point of it.
  final bool preview;

  /// Label to the band it scrolls to. Built by the caller from what is
  /// actually on the page, so a link never points at nothing.
  final Map<String, GlobalKey> anchors;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: scheme.surface,
        border: Border(bottom: BorderSide(color: Land.border(scheme))),
      ),
      padding: const EdgeInsets.symmetric(
        horizontal: Land.gutter,
        vertical: 12,
      ),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: Land.maxWidth),
          child: LayoutBuilder(
            builder: (context, constraints) {
              // The links go before the buttons do. On a phone the way
              // in is the only thing on this bar that has to survive.
              final wide = constraints.maxWidth > 760;
              return Row(
                children: [
                  // On a phone the menu is on the left and the mark is
                  // centred, which is where a thumb and an eye expect
                  // them. On a desktop the mark leads.
                  if (!wide)
                    _Burger(
                      content: content,
                      anchors: anchors,
                      preview: preview,
                      onPick: _scrollTo,
                    ),
                  LandingMark(content: content, size: 32),
                  const Spacer(),
                  if (wide) ...[
                    // The products link opens a panel of the blocks
                    // themselves rather than scrolling blindly: on a
                    // page with eight product areas, "what does it do"
                    // is answerable from the bar.
                    if (content.sections.isNotEmpty &&
                        anchors['Features'] != null)
                      _MegaMenu(
                        label: 'Products',
                        sections: content.sections,
                        onPick: () => _scrollTo(anchors['Features']!),
                      ),
                    for (final entry in anchors.entries)
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        child: TextButton(
                          onPressed: () => _scrollTo(entry.value),
                          child: Text(
                            entry.key,
                            style: TextStyle(color: scheme.onSurface),
                          ),
                        ),
                      ),
                    const SizedBox(width: 16),
                  ],
                  if (wide)
                    TextButton(
                      onPressed: preview ? null : () => context.go('/signin'),
                      child: Text(content.signInLabel),
                    ),
                  if (content.registerEnabled) ...[
                    const SizedBox(width: 8),
                    FilledButton(
                      onPressed: preview
                          ? null
                          : () => context.go('/signin?mode=register'),
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 20,
                          vertical: 16,
                        ),
                      ),
                      child: Text(content.registerLabel),
                    ),
                  ],
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  /// Nothing happens rather than a crash when the band is not built
  /// yet, which is what an anchor tapped during the first frame means.
  void _scrollTo(GlobalKey key) {
    final ctx = key.currentContext;
    if (ctx == null) return;
    Scrollable.ensureVisible(
      ctx,
      duration: const Duration(milliseconds: 400),
      curve: Curves.easeOutCubic,
    );
  }
}

/// The mark itself: the logo the console uploaded, or the built-in one
/// until somebody uploads a logo.
class LandingMark extends StatelessWidget {
  const LandingMark({super.key, required this.content, this.size = 36});

  final LandingContent content;
  final double size;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final url = (dark ? content.logoDarkUrl : null) ?? content.logoUrl;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (url != null)
          Image.network(
            url,
            height: size,
            // A logo that fails to load must not take the page with it.
            errorBuilder: (_, __, ___) => _FallbackMark(size: size),
          )
        else
          _FallbackMark(size: size),
        const SizedBox(width: 12),
        Text(
          content.wordmark,
          style: TextStyle(
            fontSize: size * 0.62,
            fontWeight: FontWeight.w700,
            color: scheme.primary,
            letterSpacing: -0.5,
          ),
        ),
      ],
    );
  }
}

class _FallbackMark extends StatelessWidget {
  const _FallbackMark({required this.size});

  final double size;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: scheme.primary,
        borderRadius: BorderRadius.circular(size * 0.28),
      ),
      child: Icon(
        Icons.account_balance_wallet,
        color: scheme.onPrimary,
        size: size * 0.6,
      ),
    );
  }
}

/// The hero, in two columns.
///
/// Copy on the left, a picture on the right — `hero_image_url`, which
/// has been a column on `landing_page` since 0290 and was read by
/// nothing until now. With no picture the right column draws a plain
/// framed panel instead of collapsing, so the shape of the page does
/// not depend on whether somebody has uploaded a screenshot yet, and
/// so nothing here invents a product shot that does not exist.
///
/// One column under 900 logical pixels, picture last.
class _Hero extends StatelessWidget {
  const _Hero({required this.content, this.preview = false});

  final LandingContent content;
  final bool preview;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final split = constraints.maxWidth > 900;
        final copy = _HeroCopy(content: content, preview: preview);
        final art = _HeroArt(content: content);
        if (!split) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [copy, const SizedBox(height: 40), art],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(flex: 6, child: copy),
            const SizedBox(width: 56),
            Expanded(flex: 5, child: art),
          ],
        );
      },
    );
  }
}

class _HeroCopy extends StatelessWidget {
  const _HeroCopy({required this.content, this.preview = false});

  final LandingContent content;
  final bool preview;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (content.tagline != null)
          Padding(
            padding: const EdgeInsets.only(bottom: Land.gap),
            child: LandingKicker(content.tagline!),
          ),
        Text(content.heroHeadline, style: Land.display(scheme)),
        if (content.heroSubhead != null) ...[
          const SizedBox(height: 20),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: Text(
              content.heroSubhead!,
              style: Land.body(scheme).copyWith(fontSize: 17),
            ),
          ),
        ],
        const SizedBox(height: 32),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            FilledButton(
              onPressed: preview
                  ? null
                  : () => context.go(
                        content.registerEnabled
                            ? '/signin?mode=register'
                            : '/signin',
                      ),
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(
                  horizontal: 28,
                  vertical: 20,
                ),
              ),
              child: Text(
                content.registerEnabled
                    ? content.registerLabel
                    : content.signInLabel,
              ),
            ),
            OutlinedButton(
              onPressed: preview ? null : () => context.go('/signin'),
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(
                  horizontal: 28,
                  vertical: 20,
                ),
                side: BorderSide(color: Land.border(scheme)),
              ),
              child: Text(content.signInLabel),
            ),
          ],
        ),
      ],
    );
  }
}

/// The right half of the hero.
///
/// The operator's screenshot when there is one. When there is not, a
/// framed panel with the shape of an application window and no content
/// in it — deliberately not a drawing of a dashboard with figures on
/// it, because a mocked-up screen with invented numbers is a picture of
/// a product that does not exist.
class _HeroArt extends StatelessWidget {
  const _HeroArt({required this.content});

  final LandingContent content;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final frame = BoxDecoration(
      borderRadius: BorderRadius.circular(Land.radiusLarge),
      color: scheme.surfaceContainerLowest,
      border: Border.all(color: Land.border(scheme)),
      boxShadow: Land.lift(scheme, hovered: true),
    );
    // Drifts against the copy beside it as the page moves. Small
    // enough to read as depth rather than as the two columns
    // disagreeing about where they are.
    return Parallax(
      factor: 0.06,
      child: content.heroImageUrl != null
          ? Container(
              decoration: frame,
              clipBehavior: Clip.antiAlias,
              child: Image.network(
                content.heroImageUrl!,
                fit: BoxFit.cover,
                // A hero that will not load must not take the page
                // with it.
                errorBuilder: (context, _, __) => const _HeroPlaceholder(),
              ),
            )
          : Container(decoration: frame, child: const _HeroPlaceholder()),
    );
  }
}

/// A drawing of the product, for the slot a screenshot has not filled.
///
/// The frame used to be empty. An empty rectangle in the half of the
/// hero that is meant to show the software says the software has
/// nothing to show, which is the opposite of what a hero is for.
///
/// So it draws the shape of the thing: a rail, a header, three summary
/// tiles, a chart and a few rows of a table. **Every value in it is a
/// grey block, and there is not one digit anywhere.** That is the whole
/// design constraint. A mocked-up dashboard reading "Revenue RM
/// 284,320 ▲ 12%" is a picture of results no customer of this platform
/// has had, on a page asking people for money — the same objection that
/// keeps `landing_stats` empty. Shapes describe the product; numbers
/// would describe an outcome.
///
/// Replaced entirely the moment `hero_image_url` is set, which is what
/// an operator should do: a screenshot of their own books beats a
/// drawing of anybody's.
class _HeroPlaceholder extends StatelessWidget {
  const _HeroPlaceholder();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final line = Land.border(scheme);
    final block = scheme.onSurface.withValues(alpha: 0.10);

    Widget bar(double w, double h, {Color? c}) => Container(
      width: w,
      height: h,
      decoration: BoxDecoration(
        color: c ?? block,
        borderRadius: BorderRadius.circular(3),
      ),
    );

    return AspectRatio(
      aspectRatio: 16 / 10,
      child: Column(
        children: [
          // The bar of an application window.
          Container(
            height: 30,
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: line)),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                for (var i = 0; i < 3; i++)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: line,
                      ),
                    ),
                  ),
                const Spacer(),
                bar(60, 6),
              ],
            ),
          ),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // The side rail.
                Container(
                  width: 54,
                  decoration: BoxDecoration(
                    border: Border(right: BorderSide(color: line)),
                  ),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 12,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      bar(20, 20, c: scheme.primary.withValues(alpha: 0.85)),
                      const SizedBox(height: 14),
                      for (var i = 0; i < 5; i++) ...[
                        bar(i == 1 ? 30 : 22, 5),
                        const SizedBox(height: 9),
                      ],
                    ],
                  ),
                ),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        bar(70, 7),
                        const SizedBox(height: 12),
                        // Three summary tiles, each a label and a value
                        // that is a block rather than a figure.
                        Row(
                          children: [
                            for (var i = 0; i < 3; i++) ...[
                              Expanded(
                                child: Container(
                                  padding: const EdgeInsets.all(9),
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(6),
                                    border: Border.all(color: line),
                                  ),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      bar(28, 4),
                                      const SizedBox(height: 7),
                                      bar(
                                        40,
                                        9,
                                        c: scheme.primary
                                            .withValues(alpha: 0.55),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                              if (i < 2) const SizedBox(width: 8),
                            ],
                          ],
                        ),
                        const SizedBox(height: 12),
                        // A chart, as columns of no stated height.
                        Expanded(
                          child: Container(
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(color: line),
                            ),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
                                for (final h in const [
                                  0.45,
                                  0.7,
                                  0.35,
                                  0.85,
                                  0.6,
                                  0.95,
                                  0.5,
                                  0.75,
                                ]) ...[
                                  Expanded(
                                    child: FractionallySizedBox(
                                      heightFactor: h,
                                      alignment: Alignment.bottomCenter,
                                      child: Container(
                                        decoration: BoxDecoration(
                                          color: scheme.primary.withValues(
                                            alpha: 0.28 + h * 0.4,
                                          ),
                                          borderRadius:
                                              const BorderRadius.vertical(
                                            top: Radius.circular(3),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                ],
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(height: 10),
                        // And the top of a ledger.
                        for (var i = 0; i < 3; i++)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 7),
                            child: Row(
                              children: [
                                bar(i.isEven ? 54 : 44, 5),
                                const Spacer(),
                                bar(30, 5),
                                const SizedBox(width: 12),
                                bar(22, 5),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The strip under the hero: what it files under.
///
/// A row of short pills rather than cards. Each names a Malaysian
/// statutory regime the software actually implements — see
/// [defaultBadges] for why these ship filled when the stats band does
/// not, and for why none of them is a certification claim.
class _Badges extends StatelessWidget {
  const _Badges({required this.badges});

  final List<LandingSection> badges;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Text(
          'Files what a Malaysian business has to file',
          textAlign: TextAlign.center,
          style: Land.small(scheme).copyWith(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: Land.gap),
        Wrap(
          alignment: WrapAlignment.center,
          spacing: 10,
          runSpacing: 10,
          children: [
            for (final b in badges)
              HoverLift(
                builder: (context, hovered) => AnimatedContainer(
                  duration: const Duration(milliseconds: 160),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 11,
                  ),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(999),
                    color: scheme.surface,
                    border: Border.all(
                      color: hovered
                          ? Land.borderHover(scheme)
                          : Land.border(scheme),
                    ),
                    boxShadow: Land.lift(scheme, hovered: hovered),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        landingIcon(b.icon),
                        size: 16,
                        color: scheme.primary,
                      ),
                      const SizedBox(width: 9),
                      Text(
                        b.title,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: scheme.onSurface,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }
}

/// What the product does, as a grid.
///
/// Three columns above 900 logical pixels, two above 560, one below —
/// the collapse is by available width rather than by device, because
/// the same page is a phone, a tablet held either way, and a browser
/// somebody has dragged to half a screen.
///
/// This was briefly a tab strip. A grid is the better call and the
/// reason is scanning: somebody deciding whether an accounting package
/// covers what they need wants every area in front of them at once, not
/// eight areas of which they can see one. Tabs hide seven eighths of
/// the answer behind a click.
class _Sections extends StatelessWidget {
  const _Sections({required this.sections});

  final List<LandingSection> sections;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const LandingSectionHeader(
          kicker: 'Product',
          title: 'Everything the books need, in one place',
          subtitle: 'One ledger underneath all of it, so a sale at the '
              'counter and a payroll run land in the same accounts.',
        ),
        const SizedBox(height: Land.gapLg),
        LayoutBuilder(
          builder: (context, constraints) {
            final columns = constraints.maxWidth > 900
                ? 3
                : constraints.maxWidth > 560
                    ? 2
                    : 1;
            final width =
                (constraints.maxWidth - (columns - 1) * Land.gap) / columns;
            return Wrap(
              spacing: Land.gap,
              runSpacing: Land.gap,
              children: [
                for (final s in sections)
                  SizedBox(
                    width: width,
                    child: RevealOnScroll(
                      // Staggered by position so a row arrives as a
                      // row. Capped, or the last card on a long page
                      // waits a second and a half to say anything.
                      delay: Duration(
                        milliseconds: 60 * (sections.indexOf(s) % 6),
                      ),
                      child: _FeatureCard(section: s),
                    ),
                  ),
              ],
            );
          },
        ),
      ],
    );
  }
}

class _FeatureCard extends StatelessWidget {
  const _FeatureCard({required this.section});

  final LandingSection section;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return HoverLift(
      builder: (context, hovered) => AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        padding: const EdgeInsets.all(Land.gapLg - 8),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(Land.radius),
          color: scheme.surface,
          border: Border.all(
            color: hovered ? Land.borderHover(scheme) : Land.border(scheme),
          ),
          boxShadow: Land.lift(scheme, hovered: hovered),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(Land.radiusTight),
                color: scheme.primary.withValues(
                  alpha: hovered ? 0.16 : 0.09,
                ),
              ),
              child: Icon(
                landingIcon(section.icon),
                color: scheme.primary,
                size: 22,
              ),
            ),
            const SizedBox(height: 16),
            Text(section.title, style: Land.cardTitle(scheme)),
            if (section.body != null) ...[
              const SizedBox(height: Land.gapSm),
              Text(
                section.body!,
                style: Land.body(scheme).copyWith(
                  fontSize: 14,
                  height: 1.55,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// The icon a section asked for, or a neutral one.
///
/// A small named set rather than anything the console types, because
/// Flutter tree-shakes icons it cannot see at build time: an icon looked
/// up by an arbitrary string at run time is an icon that is not in the
/// bundle.
IconData landingIcon(String? name) {
  switch (name) {
    case 'receipt':
      return Icons.receipt_long;
    // A different glyph from `receipt`, which the e-Invoice block has
    // held since 0290 and should keep.
    case 'expenses':
      return Icons.receipt;
    case 'payments':
      return Icons.payments;
    case 'people':
      return Icons.groups;
    case 'inventory':
      return Icons.inventory_2;
    case 'store':
      return Icons.storefront;
    case 'insights':
      return Icons.insights;
    case 'shield':
      return Icons.verified_user;
    case 'cloud':
      return Icons.cloud_done;
    // 0317's reasons, and what a stats band tends to ask for.
    case 'gavel':
      return Icons.gavel;
    case 'calculate':
      return Icons.calculate;
    case 'lock':
      return Icons.lock;
    case 'devices':
      return Icons.devices;
    case 'sync_alt':
      return Icons.sync_alt;
    case 'support':
      return Icons.support_agent;
    case 'schedule':
      return Icons.schedule;
    case 'star':
      return Icons.star;
    case 'trending_up':
      return Icons.trending_up;
    case 'handshake':
      return Icons.handshake;
    default:
      return Icons.check_circle;
  }
}

class _AppLinks extends StatelessWidget {
  const _AppLinks({required this.links, this.preview = false});

  final List<LandingAppLink> links;
  final bool preview;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const LandingSectionHeader(
          kicker: 'Download',
          title: 'Get the app',
        ),
        const SizedBox(height: Land.gapLg),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            for (final l in links)
              // The lift only; the button keeps the tap. Two things
              // listening for the same tap is how a store link opens
              // twice on the day somebody changes one of them.
              HoverLift(
                builder: (context, hovered) => OutlinedButton.icon(
                  onPressed: preview ? null : () => launchExternal(l.url),
                  icon: Icon(storeIcon(l.storeCode)),
                  label: Text(l.label),
                  style: OutlinedButton.styleFrom(
                    side: BorderSide(
                      color: hovered
                          ? Land.borderHover(scheme)
                          : Land.border(scheme),
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

/// Which glyph goes on which shop's button.
///
/// Named for the same reason [landingIcon] is: the set has to be visible
/// at build time or the icon is not in the bundle.
IconData storeIcon(String storeCode) {
  switch (storeCode) {
    case 'app_store':
      return Icons.phone_iphone;
    case 'play_store':
      return Icons.shop;
    case 'appgallery':
      return Icons.apps;
    case 'galaxy_store':
      return Icons.smartphone;
    case 'web':
      return Icons.language;
    default:
      return Icons.download;
  }
}

/// The foot of the page.
///
/// A grey band with columns rather than the four stacked lines it was:
/// who the company is on the left, the two link columns that have
/// somewhere real to point, and a rule with the copyright under it.
///
/// Every link here goes to something that exists. A sitemap of headings
/// with nothing behind them looks like a bigger company and behaves
/// like a broken one, so a column with nothing in it is not rendered.
class _Footer extends StatelessWidget {
  const _Footer({required this.content, this.preview = false});

  final LandingContent content;
  final bool preview;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final small = Land.small(scheme);

    final company = <String>[
      if (content.companyName != null)
        content.companyRegNo != null
            ? '${content.companyName} (${content.companyRegNo})'
            : content.companyName!,
      if (content.address != null) content.address!,
    ];
    final contact = <(String, String?)>[
      if (content.supportEmail != null)
        (content.supportEmail!, 'mailto:${content.supportEmail}'),
      if (content.supportPhone != null) (content.supportPhone!, null),
    ];
    final legal = <(String, String)>[
      if (content.privacyUrl != null) ('Privacy', content.privacyUrl!),
      if (content.termsUrl != null) ('Terms', content.termsUrl!),
    ];

    return Container(
      width: double.infinity,
      color: scheme.surfaceContainerLowest,
      padding: const EdgeInsets.symmetric(
        horizontal: Land.gutter,
        vertical: Land.bandYTight,
      ),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: Land.maxWidth),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: 64,
                runSpacing: 32,
                children: [
                  SizedBox(
                    width: 300,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        LandingMark(content: content, size: 30),
                        if (content.tagline != null) ...[
                          const SizedBox(height: 12),
                          Text(content.tagline!, style: small),
                        ],
                        if (company.isNotEmpty) ...[
                          const SizedBox(height: 12),
                          for (final line in company)
                            Text(line, style: small),
                        ],
                      ],
                    ),
                  ),
                  _FooterColumn(
                    heading: 'Get started',
                    children: [
                      _FooterLink(
                        label: content.signInLabel,
                        onTap: preview ? null : () => context.go('/signin'),
                      ),
                      if (content.registerEnabled)
                        _FooterLink(
                          label: content.registerLabel,
                          onTap: preview
                              ? null
                              : () => context.go('/signin?mode=register'),
                        ),
                    ],
                  ),
                  if (contact.isNotEmpty)
                    _FooterColumn(
                      heading: 'Contact',
                      children: [
                        for (final (label, url) in contact)
                          url == null
                              ? Padding(
                                  padding: const EdgeInsets.only(bottom: 6),
                                  child: Text(label, style: small),
                                )
                              : _FooterLink(
                                  label: label,
                                  onTap: preview
                                      ? null
                                      : () => launchExternal(url),
                                ),
                      ],
                    ),
                  if (legal.isNotEmpty)
                    _FooterColumn(
                      heading: 'Legal',
                      children: [
                        for (final (label, url) in legal)
                          _FooterLink(
                            label: label,
                            onTap:
                                preview ? null : () => launchExternal(url),
                          ),
                      ],
                    ),
                ],
              ),
              const SizedBox(height: 40),
              Divider(color: Land.border(scheme), height: 1),
              const SizedBox(height: 20),
              Text(
                '© ${DateTime.now().year} '
                '${content.companyName ?? content.wordmark}',
                style: small,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _FooterColumn extends StatelessWidget {
  const _FooterColumn({required this.heading, required this.children});

  final String heading;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      width: 180,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            heading,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.4,
              color: scheme.onSurface,
            ),
          ),
          const SizedBox(height: 12),
          ...children,
        ],
      ),
    );
  }
}

class _FooterLink extends StatelessWidget {
  const _FooterLink({required this.label, required this.onTap});

  final String label;

  /// Null in the console's preview: the link is drawn and inert.
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: HoverLift(
        builder: (context, hovered) => InkWell(
          onTap: onTap,
          child: Text(
            label,
            style: TextStyle(
              fontSize: 13,
              height: 1.7,
              color: hovered ? scheme.primary : scheme.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }
}

/// The band partway down, for somebody who has read enough.
///
/// One line, a sentence under it, and a button. Rendered only when a
/// headline is set; the button only when there is both a label and
/// somewhere for it to go, because a button that does nothing reads as
/// a broken page rather than as a missing setting.
class _Cta extends StatelessWidget {
  const _Cta({required this.content, this.preview = false});

  final LandingContent content;
  final bool preview;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final hasButton = content.ctaLabel != null && content.ctaUrl != null;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 44),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(Land.radiusLarge),
        color: scheme.primary,
        boxShadow: Land.lift(scheme, hovered: true),
      ),
      child: Wrap(
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 24,
        runSpacing: 20,
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 620),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  content.ctaHeadline!,
                  style: Land.heading(scheme).copyWith(
                    fontSize: 27,
                    color: scheme.onPrimary,
                  ),
                ),
                if (content.ctaBody != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    content.ctaBody!,
                    style: Land.body(scheme).copyWith(
                      color: scheme.onPrimary.withValues(alpha: 0.86),
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (hasButton)
            FilledButton(
              onPressed:
                  preview ? null : () => launchExternal(content.ctaUrl),
              style: FilledButton.styleFrom(
                backgroundColor: scheme.onPrimary,
                foregroundColor: scheme.primary,
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 18,
                ),
              ),
              child: Text(content.ctaLabel!),
            ),
        ],
      ),
    );
  }
}

/// Why choose this one, as against what it does.
///
/// A two-column list of icon, line and sentence, rather than a second
/// grid of cards. The feature band above is the grid; repeating that
/// shape here would make the page read as one long grid interrupted by
/// headings, and a reader skimming would not register that the second
/// band is answering a different question.
class _Reasons extends StatelessWidget {
  const _Reasons({required this.reasons});

  final List<LandingSection> reasons;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const LandingSectionHeader(
          kicker: 'Why us',
          title: 'Built for the rules you actually file under',
          subtitle: 'Not a foreign package with a Malaysian tax code bolted '
              'on the side.',
        ),
        const SizedBox(height: Land.gapLg),
        LayoutBuilder(
          builder: (context, constraints) {
            final columns = constraints.maxWidth > 760 ? 2 : 1;
            final width =
                (constraints.maxWidth - (columns - 1) * Land.gapLg) / columns;
            return Wrap(
              spacing: Land.gapLg,
              runSpacing: Land.gapLg - 6,
              children: [
                for (final r in reasons)
                  SizedBox(
                    width: width,
                    child: RevealOnScroll(
                      delay: Duration(
                        milliseconds: 60 * (reasons.indexOf(r) % 6),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Container(
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              borderRadius:
                                  BorderRadius.circular(Land.radiusTight),
                              color: scheme.primary.withValues(alpha: 0.09),
                            ),
                            child: Icon(
                              landingIcon(r.icon),
                              color: scheme.primary,
                              size: 18,
                            ),
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  r.title,
                                  style: Land.cardTitle(scheme)
                                      .copyWith(fontSize: 16),
                                ),
                                if (r.body != null) ...[
                                  const SizedBox(height: 6),
                                  Text(
                                    r.body!,
                                    style: Land.body(scheme).copyWith(
                                      fontSize: 14,
                                      height: 1.55,
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
      ],
    );
  }
}

/// The band of figures.
///
/// Empty unless a platform administrator has written rows: how many
/// businesses use a platform is a claim about the world, and this file
/// is in no position to make it. [LandingContent.stats] ships empty and
/// the whole band is skipped, rather than showing a row of zeroes or a
/// placeholder somebody forgets to replace.
class _Stats extends StatelessWidget {
  const _Stats({required this.stats});

  final List<LandingStat> stats;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 40),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(Land.radiusLarge),
        color: scheme.surfaceContainerLowest,
        border: Border.all(color: Land.border(scheme)),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final columns = constraints.maxWidth > 760
              ? (stats.length < 4 ? stats.length : 4)
              : constraints.maxWidth > 420
                  ? 2
                  : 1;
          final width =
              (constraints.maxWidth - (columns - 1) * Land.gapLg) / columns;
          return Wrap(
            spacing: Land.gapLg,
            runSpacing: Land.gapLg,
            children: [
              for (final s in stats)
                SizedBox(
                  width: width,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (s.icon != null) ...[
                        Icon(
                          landingIcon(s.icon),
                          color: scheme.primary,
                          size: 22,
                        ),
                        const SizedBox(height: 10),
                      ],
                      // The figure exactly as it was typed. A stat is a
                      // string in the database for this reason: nobody
                      // has to guess whether "240,000" wanted a
                      // thousands separator.
                      CountUp(
                        s.value,
                        style: Land.display(scheme).copyWith(
                          fontSize: 38,
                          letterSpacing: -1.6,
                          color: scheme.primary,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(s.label, style: Land.small(scheme)),
                    ],
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

/// What customers say, in a speech bubble with a name under it.
///
/// The shape the reference page uses, and the right one: a quote set as
/// a bubble is unmistakably somebody talking, where a quote in a
/// bordered card reads as more product copy in the product's own voice.
///
/// Ships empty and stays empty until somebody writes one. There is no
/// built-in copy to fall back on and the author is rendered every time
/// — a testimonial nobody said is a fabricated endorsement whatever
/// else it is, and an unattributed quote on a page selling software is
/// exactly the shape an invented one takes.
class _Testimonials extends StatelessWidget {
  const _Testimonials({required this.testimonials});

  final List<LandingTestimonial> testimonials;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const LandingSectionHeader(
          kicker: 'Customers',
          title: 'What customers say',
        ),
        const SizedBox(height: Land.gapLg),
        LayoutBuilder(
          builder: (context, constraints) {
            final columns = constraints.maxWidth > 900
                ? 3
                : constraints.maxWidth > 560
                    ? 2
                    : 1;
            final width =
                (constraints.maxWidth - (columns - 1) * Land.gap) / columns;
            return Wrap(
              spacing: Land.gap,
              runSpacing: Land.gapLg,
              children: [
                for (final t in testimonials)
                  SizedBox(
                    width: width,
                    child: RevealOnScroll(
                      delay: Duration(
                        milliseconds: 60 * (testimonials.indexOf(t) % 6),
                      ),
                      child: _Bubble(testimonial: t),
                    ),
                  ),
              ],
            );
          },
        ),
      ],
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({required this.testimonial});

  final LandingTestimonial testimonial;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(Land.gapLg - 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(Land.radius),
            color: scheme.primary,
          ),
          child: Text(
            testimonial.quote,
            style: TextStyle(
              fontSize: 15,
              height: 1.6,
              color: scheme.onPrimary,
            ),
          ),
        ),
        // The tail, under the left edge, so the bubble points at the
        // person named below it rather than at nothing.
        Padding(
          padding: const EdgeInsets.only(left: 28),
          child: CustomPaint(
            size: const Size(22, 12),
            painter: _TailPainter(scheme.primary),
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            if (testimonial.avatarUrl != null) ...[
              ClipRRect(
                borderRadius: BorderRadius.circular(Land.radiusTight),
                child: Image.network(
                  testimonial.avatarUrl!,
                  width: 40,
                  height: 40,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                ),
              ),
              const SizedBox(width: 12),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    testimonial.author,
                    style: Land.cardTitle(scheme).copyWith(fontSize: 15),
                  ),
                  if (testimonial.company != null)
                    Text(
                      testimonial.company!,
                      style: Land.small(scheme).copyWith(fontSize: 13),
                    ),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _TailPainter extends CustomPainter {
  const _TailPainter(this.colour);

  final Color colour;

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..moveTo(0, 0)
      ..lineTo(size.width, 0)
      ..lineTo(0, size.height)
      ..close();
    canvas.drawPath(path, Paint()..color = colour);
  }

  @override
  bool shouldRepaint(_TailPainter old) => old.colour != colour;
}

/// The wall of customer marks.
///
/// Ships empty. Putting a company's logo on a page says they are a
/// customer, which is theirs to agree to and not this file's to assume.
class _Logos extends StatelessWidget {
  const _Logos({required this.logos});

  final List<LandingLogo> logos;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const LandingKicker('Trusted by'),
        const SizedBox(height: Land.gap),
        Wrap(
          spacing: 32,
          runSpacing: 20,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            for (final l in logos)
              // The name is the tooltip and the fallback both: an image
              // that will not load leaves the customer named rather
              // than leaving a broken box on a wall of customers.
              Tooltip(
                message: l.name,
                child: Image.network(
                  l.logoUrl,
                  height: 34,
                  fit: BoxFit.contain,
                  errorBuilder: (context, _, __) => Text(
                    l.name,
                    style: Land.small(scheme).copyWith(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
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

/// The panel that drops from the bar.
///
/// Opened on hover with a short grace period on the way out, because a
/// menu that closes the instant the pointer leaves the label is a menu
/// nobody can reach the contents of — the pointer has to cross the gap
/// between the label and the panel to get there.
///
/// Its contents are the feature blocks, so it is the console's rows
/// rather than a second list to keep in step. Picking one closes the
/// panel and scrolls to the band, which is the honest behaviour for a
/// site with no other pages: this is a table of contents, not
/// navigation, and a menu item that looked like a link to a page that
/// does not exist would be worse than no menu.
class _MegaMenu extends StatefulWidget {
  const _MegaMenu({
    required this.label,
    required this.sections,
    required this.onPick,
  });

  final String label;
  final List<LandingSection> sections;
  final VoidCallback onPick;

  @override
  State<_MegaMenu> createState() => _MegaMenuState();
}

class _MegaMenuState extends State<_MegaMenu> {
  final _link = LayerLink();
  OverlayEntry? _entry;
  bool _overLabel = false;
  bool _overPanel = false;

  @override
  void dispose() {
    _entry?.remove();
    _entry = null;
    super.dispose();
  }

  void _sync() {
    // A beat later, so a pointer travelling from the label into the
    // panel is never counted as being over neither.
    Future<void>.delayed(const Duration(milliseconds: 130), () {
      if (!mounted) return;
      final wanted = _overLabel || _overPanel;
      if (wanted && _entry == null) {
        _entry = _build();
        Overlay.of(context).insert(_entry!);
      } else if (!wanted && _entry != null) {
        _entry!.remove();
        _entry = null;
      }
    });
  }

  void _close() {
    _entry?.remove();
    _entry = null;
    _overLabel = false;
    _overPanel = false;
  }

  OverlayEntry _build() {
    final scheme = Theme.of(context).colorScheme;
    return OverlayEntry(
      builder: (context) => Positioned(
        width: 640,
        child: CompositedTransformFollower(
          link: _link,
          targetAnchor: Alignment.bottomLeft,
          followerAnchor: Alignment.topLeft,
          offset: const Offset(-40, 10),
          child: MouseRegion(
            onEnter: (_) {
              _overPanel = true;
              _sync();
            },
            onExit: (_) {
              _overPanel = false;
              _sync();
            },
            child: Material(
              color: Colors.transparent,
              child: Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(Land.radius),
                  color: scheme.surface,
                  border: Border.all(color: Land.border(scheme)),
                  boxShadow: [
                    BoxShadow(
                      color: scheme.shadow.withValues(alpha: 0.13),
                      blurRadius: 28,
                      offset: const Offset(0, 10),
                    ),
                  ],
                ),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final s in widget.sections)
                      SizedBox(
                        width: 296,
                        child: HoverLift(
                          builder: (context, hovered) => InkWell(
                            borderRadius: BorderRadius.circular(
                              Land.radiusTight,
                            ),
                            onTap: () {
                              setState(_close);
                              widget.onPick();
                            },
                            child: AnimatedContainer(
                              duration: const Duration(milliseconds: 140),
                              padding: const EdgeInsets.all(10),
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(
                                  Land.radiusTight,
                                ),
                                color: hovered
                                    ? scheme.surfaceContainerLowest
                                    : Colors.transparent,
                              ),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Icon(
                                    landingIcon(s.icon),
                                    size: 18,
                                    color: scheme.primary,
                                  ),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          s.title,
                                          style: TextStyle(
                                            fontSize: 14,
                                            fontWeight: FontWeight.w700,
                                            color: scheme.onSurface,
                                          ),
                                        ),
                                        if (s.body != null) ...[
                                          const SizedBox(height: 3),
                                          Text(
                                            s.body!,
                                            maxLines: 2,
                                            overflow: TextOverflow.ellipsis,
                                            style: Land.small(
                                              scheme,
                                            ).copyWith(height: 1.45),
                                          ),
                                        ],
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return CompositedTransformTarget(
      link: _link,
      child: MouseRegion(
        onEnter: (_) {
          _overLabel = true;
          _sync();
        },
        onExit: (_) {
          _overLabel = false;
          _sync();
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: TextButton(
            onPressed: () {
              setState(_close);
              widget.onPick();
            },
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(widget.label, style: TextStyle(color: scheme.onSurface)),
                const SizedBox(width: 4),
                Icon(
                  Icons.keyboard_arrow_down,
                  size: 17,
                  color: Land.muted(scheme),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The menu button, and the sheet it opens.
///
/// Every frame of the reference on a phone shows this: a burger on the
/// left, the mark centred, and nothing else on the bar. The page has
/// four or five anchors and two ways in, which is two rows of controls
/// at 390 logical pixels and one row at 1200 — so on a phone they go
/// behind the button.
///
/// A bottom sheet rather than a side drawer. A drawer needs a Scaffold
/// with one attached, and this page is drawn inside the console's
/// preview as well as at the front door; a sheet works in both without
/// either caring.
class _Burger extends StatelessWidget {
  const _Burger({
    required this.content,
    required this.anchors,
    required this.preview,
    required this.onPick,
  });

  final LandingContent content;
  final Map<String, GlobalKey> anchors;
  final bool preview;
  final void Function(GlobalKey) onPick;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return IconButton(
      icon: const Icon(Icons.menu),
      color: scheme.onSurface,
      tooltip: 'Menu',
      onPressed: () => showModalBottomSheet<void>(
        context: context,
        showDragHandle: true,
        backgroundColor: scheme.surface,
        builder: (sheet) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final entry in anchors.entries)
                ListTile(
                  title: Text(entry.key, style: Land.cardTitle(scheme)),
                  trailing: Icon(
                    Icons.arrow_downward,
                    size: 18,
                    color: Land.muted(scheme),
                  ),
                  onTap: () {
                    Navigator.of(sheet).pop();
                    onPick(entry.value);
                  },
                ),
              Divider(color: Land.border(scheme), height: 1),
              Padding(
                padding: const EdgeInsets.all(Land.gap),
                child: Column(
                  children: [
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton(
                        onPressed: preview
                            ? null
                            : () {
                                Navigator.of(sheet).pop();
                                context.go('/signin');
                              },
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 18),
                          side: BorderSide(color: Land.border(scheme)),
                        ),
                        child: Text(content.signInLabel),
                      ),
                    ),
                    if (content.registerEnabled) ...[
                      const SizedBox(height: 10),
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton(
                          onPressed: preview
                              ? null
                              : () {
                                  Navigator.of(sheet).pop();
                                  context.go('/signin?mode=register');
                                },
                          style: FilledButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 18),
                          ),
                          child: Text(content.registerLabel),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
