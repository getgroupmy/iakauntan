import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/safe_link.dart';
import 'landing_content.dart';
import 'landing_motion.dart';
import 'landing_pricing.dart';

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
    final content = fetched.valueOrNull ?? LandingContent.fallback;
    final scheme = Theme.of(context).colorScheme;

    // Anchors for the masthead's links. A landing page whose navigation
    // points at pages that do not exist is worse than one with no
    // navigation, so these scroll to bands on this page and there is a
    // key only where there is a band.
    final features = GlobalKey();
    final why = GlobalKey();
    final pricing = GlobalKey();
    final apps = GlobalKey();

    return Scaffold(
      backgroundColor: scheme.surface,
      body: SafeArea(
        child: Column(
          children: [
            // Pinned rather than scrolled away with the hero. The way
            // in is the point of this page and it should not require
            // scrolling back to the top to find.
            _Masthead(
              content: content,
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
                      child: RevealOnScroll(child: _Hero(content: content)),
                    ),
                    if (content.sections.isNotEmpty)
                      _Band(
                        key: features,
                        tinted: true,
                        child: _Sections(sections: content.sections),
                      ),
                    // Somewhere to press, for a visitor who has read
                    // the feature panel and does not need the rest.
                    if (content.ctaHeadline != null)
                      _Band(
                        child: RevealOnScroll(child: _Cta(content: content)),
                      ),
                    if (content.reasons.isNotEmpty)
                      _Band(
                        key: why,
                        tinted: content.ctaHeadline == null,
                        child: _Reasons(reasons: content.reasons),
                      ),
                    // The three that ship empty. Each renders nothing
                    // at all until an operator has written rows, which
                    // is the correct page for a platform that has not
                    // made a claim rather than a gap to fill with
                    // invented ones.
                    if (content.stats.isNotEmpty)
                      _Band(
                        child: RevealOnScroll(
                          child: _Stats(stats: content.stats),
                        ),
                      ),
                    if (content.testimonials.isNotEmpty)
                      _Band(
                        tinted: true,
                        child:
                            _Testimonials(testimonials: content.testimonials),
                      ),
                    if (content.logos.isNotEmpty)
                      _Band(
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
                          child: _AppLinks(links: content.appLinks),
                        ),
                      ),
                    _Footer(content: content),
                  ],
                ),
              ),
            ),
          ],
        ),
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
  const _Band({super.key, required this.child, this.tinted = false});

  final Widget child;

  /// Whether this band sits on the faint grey that separates it from
  /// the ones either side. Alternating rather than every other one by
  /// index, because which bands render at all depends on what the
  /// operator has written.
  final bool tinted;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      color: tinted ? scheme.surfaceContainerLowest : scheme.surface,
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 64),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1160),
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
  const _Masthead({required this.content, required this.anchors});

  final LandingContent content;

  /// Label to the band it scrolls to. Built by the caller from what is
  /// actually on the page, so a link never points at nothing.
  final Map<String, GlobalKey> anchors;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: scheme.surface,
        border: Border(bottom: BorderSide(color: scheme.outlineVariant)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1160),
          child: LayoutBuilder(
            builder: (context, constraints) {
              // The links go before the buttons do. On a phone the way
              // in is the only thing on this bar that has to survive.
              final wide = constraints.maxWidth > 760;
              return Row(
                children: [
                  LandingMark(content: content, size: 32),
                  const Spacer(),
                  if (wide) ...[
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
                  TextButton(
                    onPressed: () => context.go('/signin'),
                    child: Text(content.signInLabel),
                  ),
                  if (content.registerEnabled) ...[
                    const SizedBox(width: 8),
                    FilledButton(
                      onPressed: () => context.go('/signin?mode=register'),
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
  const _Hero({required this.content});

  final LandingContent content;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final split = constraints.maxWidth > 900;
        final copy = _HeroCopy(content: content);
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
  const _HeroCopy({required this.content});

  final LandingContent content;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (content.tagline != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: Text(
              content.tagline!.toUpperCase(),
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.4,
                color: scheme.primary,
              ),
            ),
          ),
        Text(
          content.heroHeadline,
          style: TextStyle(
            fontSize: 46,
            height: 1.1,
            fontWeight: FontWeight.w800,
            letterSpacing: -1.2,
            color: scheme.onSurface,
          ),
        ),
        if (content.heroSubhead != null) ...[
          const SizedBox(height: 20),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: Text(
              content.heroSubhead!,
              style: TextStyle(
                fontSize: 17,
                height: 1.6,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
        const SizedBox(height: 32),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            FilledButton(
              onPressed: () => context.go(
                content.registerEnabled ? '/signin?mode=register' : '/signin',
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
              onPressed: () => context.go('/signin'),
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(
                  horizontal: 28,
                  vertical: 20,
                ),
                side: BorderSide(color: scheme.outlineVariant),
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
      borderRadius: BorderRadius.circular(16),
      color: scheme.surfaceContainerLowest,
      border: Border.all(color: scheme.outlineVariant),
    );
    if (content.heroImageUrl != null) {
      return Container(
        decoration: frame,
        clipBehavior: Clip.antiAlias,
        child: Image.network(
          content.heroImageUrl!,
          fit: BoxFit.cover,
          // A hero that will not load must not take the page with it.
          errorBuilder: (context, _, __) => const _HeroPlaceholder(),
        ),
      );
    }
    return Container(decoration: frame, child: const _HeroPlaceholder());
  }
}

class _HeroPlaceholder extends StatelessWidget {
  const _HeroPlaceholder();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AspectRatio(
      aspectRatio: 16 / 10,
      child: Column(
        children: [
          // The bar of an application window, and nothing under it.
          Container(
            height: 34,
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(color: scheme.outlineVariant),
              ),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: Row(
              children: [
                for (var i = 0; i < 3; i++)
                  Padding(
                    padding: const EdgeInsets.only(right: 7),
                    child: Container(
                      width: 9,
                      height: 9,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: scheme.outlineVariant,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          Expanded(
            child: Center(
              child: Icon(
                Icons.insert_chart_outlined,
                size: 44,
                color: scheme.outlineVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// What the product does, one area at a time.
///
/// A strip of tabs across the top and one pane under it, rather than
/// eight cards a visitor scrolls past. The tabs are the section titles
/// the console wrote, so a platform that has written its own blocks
/// gets its own tabs and one that has not gets the eight this
/// repository ships with.
///
/// Under 720 logical pixels the strip becomes a stack of cards: a row
/// of eight tabs on a phone is a row of eight tabs nobody can read.
class _Sections extends StatefulWidget {
  const _Sections({required this.sections});

  final List<LandingSection> sections;

  @override
  State<_Sections> createState() => _SectionsState();
}

class _SectionsState extends State<_Sections> {
  int _selected = 0;

  @override
  void didUpdateWidget(_Sections old) {
    super.didUpdateWidget(old);
    // The console can shorten the list while somebody is looking at
    // it — the page is live — and a selection past the end would throw
    // on the next build.
    if (_selected >= widget.sections.length) _selected = 0;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth <= 720) {
          return _SectionCards(sections: widget.sections);
        }
        final current = widget.sections[_selected];
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'What it does',
              style: TextStyle(
                fontSize: 26,
                fontWeight: FontWeight.w800,
                letterSpacing: -0.5,
                color: scheme.onSurface,
              ),
            ),
            const SizedBox(height: 24),
            // Scrollable, because the number of tabs is whatever the
            // console wrote and a fixed row would clip the last one.
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (var i = 0; i < widget.sections.length; i++)
                    _Tab(
                      label: widget.sections[i].title,
                      icon: landingIcon(widget.sections[i].icon),
                      selected: i == _selected,
                      onTap: () => setState(() => _selected = i),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 28),
            // Keyed by index so the pane animates when the tab moves
            // rather than mutating text in place.
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 220),
              child: _SectionPane(
                key: ValueKey(_selected),
                section: current,
              ),
            ),
          ],
        );
      },
    );
  }
}

class _Tab extends StatelessWidget {
  const _Tab({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: HoverLift(
        builder: (context, hovered) => InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(10),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              color: selected
                  ? scheme.primary
                  : hovered
                      ? scheme.surfaceContainerLowest
                      : Colors.transparent,
              border: Border.all(
                color: selected ? scheme.primary : scheme.outlineVariant,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  icon,
                  size: 18,
                  color: selected ? scheme.onPrimary : scheme.primary,
                ),
                const SizedBox(width: 9),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: selected ? scheme.onPrimary : scheme.onSurface,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The pane under the tabs: the block's copy, and the same empty window
/// frame the hero uses beside it.
class _SectionPane extends StatelessWidget {
  const _SectionPane({super.key, required this.section});

  final LandingSection section;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(32),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        color: scheme.surface,
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final copy = Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(11),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  color: scheme.primary.withValues(alpha: 0.10),
                ),
                child: Icon(
                  landingIcon(section.icon),
                  color: scheme.primary,
                  size: 24,
                ),
              ),
              const SizedBox(height: 18),
              Text(
                section.title,
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w700,
                  color: scheme.onSurface,
                ),
              ),
              if (section.body != null) ...[
                const SizedBox(height: 12),
                Text(
                  section.body!,
                  style: TextStyle(
                    fontSize: 15,
                    height: 1.65,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ],
          );
          if (constraints.maxWidth <= 820) return copy;
          return Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(flex: 5, child: copy),
              const SizedBox(width: 40),
              Expanded(
                flex: 4,
                child: Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(14),
                    color: scheme.surfaceContainerLowest,
                    border: Border.all(color: scheme.outlineVariant),
                  ),
                  child: const _HeroPlaceholder(),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// The same blocks stacked, for a screen too narrow for a tab strip.
class _SectionCards extends StatelessWidget {
  const _SectionCards({required this.sections});

  final List<LandingSection> sections;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'What it does',
          style: TextStyle(
            fontSize: 24,
            fontWeight: FontWeight.w800,
            color: scheme.onSurface,
          ),
        ),
        const SizedBox(height: 20),
        for (final s in sections)
          Padding(
            padding: const EdgeInsets.only(bottom: 14),
            child: Container(
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                color: scheme.surface,
                border: Border.all(color: scheme.outlineVariant),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        landingIcon(s.icon),
                        color: scheme.primary,
                        size: 20,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          s.title,
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ],
                  ),
                  if (s.body != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      s.body!,
                      style: TextStyle(
                        fontSize: 14,
                        height: 1.5,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
      ],
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
  const _AppLinks({required this.links});

  final List<LandingAppLink> links;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Get the app',
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.w700,
            color: scheme.onSurface,
          ),
        ),
        const SizedBox(height: 16),
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
                  onPressed: () => launchExternal(l.url),
                  icon: Icon(storeIcon(l.storeCode)),
                  label: Text(l.label),
                  style: OutlinedButton.styleFrom(
                    side: BorderSide(
                      color: hovered ? scheme.primary : scheme.outlineVariant,
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
  const _Footer({required this.content});

  final LandingContent content;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final small = TextStyle(
      fontSize: 13,
      height: 1.7,
      color: scheme.onSurfaceVariant,
    );

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
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 48),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1160),
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
                        onTap: () => context.go('/signin'),
                      ),
                      if (content.registerEnabled)
                        _FooterLink(
                          label: content.registerLabel,
                          onTap: () => context.go('/signin?mode=register'),
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
                                  onTap: () => launchExternal(url),
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
                            onTap: () => launchExternal(url),
                          ),
                      ],
                    ),
                ],
              ),
              const SizedBox(height: 40),
              Divider(color: scheme.outlineVariant, height: 1),
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
  final VoidCallback onTap;

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
  const _Cta({required this.content});

  final LandingContent content;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final hasButton = content.ctaLabel != null && content.ctaUrl != null;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 32),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        color: scheme.primary,
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
                  style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.w700,
                    height: 1.25,
                    color: scheme.onPrimary,
                  ),
                ),
                if (content.ctaBody != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    content.ctaBody!,
                    style: TextStyle(
                      fontSize: 15,
                      height: 1.5,
                      color: scheme.onPrimary.withValues(alpha: 0.86),
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (hasButton)
            FilledButton(
              onPressed: () => launchExternal(content.ctaUrl),
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
/// The grid the feature blocks used to be, now that those are a tab
/// strip: three columns of plain white cards on a crisp border, small
/// icon, one line and a sentence. Same rows from `landing_sections`
/// split by `kind`, so one console card fills both bands.
class _Reasons extends StatelessWidget {
  const _Reasons({required this.reasons});

  final List<LandingSection> reasons;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Why iAkauntan',
          style: TextStyle(
            fontSize: 26,
            fontWeight: FontWeight.w800,
            letterSpacing: -0.5,
            color: scheme.onSurface,
          ),
        ),
        const SizedBox(height: 24),
        LayoutBuilder(
          builder: (context, constraints) {
            final columns = constraints.maxWidth > 900
                ? 3
                : constraints.maxWidth > 560
                    ? 2
                    : 1;
            final width =
                (constraints.maxWidth - (columns - 1) * 20) / columns;
            return Wrap(
              spacing: 20,
              runSpacing: 20,
              children: [
                for (final r in reasons)
                  SizedBox(
                    width: width,
                    child: RevealOnScroll(
                      // Staggered by position so a row arrives as a
                      // row. Capped, or the last card on a long page
                      // waits a second and a half to say anything.
                      delay: Duration(
                        milliseconds: 60 * (reasons.indexOf(r) % 6),
                      ),
                      child: HoverLift(
                        builder: (context, hovered) => AnimatedContainer(
                          duration: const Duration(milliseconds: 160),
                          padding: const EdgeInsets.all(24),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(12),
                            color: scheme.surface,
                            border: Border.all(
                              color: hovered
                                  ? scheme.primary
                                  : scheme.outlineVariant,
                            ),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Icon(
                                landingIcon(r.icon),
                                color: scheme.primary,
                                size: 24,
                              ),
                              const SizedBox(height: 16),
                              Text(
                                r.title,
                                style: const TextStyle(
                                  fontSize: 17,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              if (r.body != null) ...[
                                const SizedBox(height: 8),
                                Text(
                                  r.body!,
                                  style: TextStyle(
                                    fontSize: 14,
                                    height: 1.55,
                                    color: scheme.onSurfaceVariant,
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
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
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 28),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        color: scheme.surfaceContainerLowest,
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final columns = constraints.maxWidth > 760
              ? (stats.length < 4 ? stats.length : 4)
              : constraints.maxWidth > 420
                  ? 2
                  : 1;
          final width = (constraints.maxWidth - (columns - 1) * 24) / columns;
          return Wrap(
            spacing: 24,
            runSpacing: 24,
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
                      Text(
                        s.value,
                        style: TextStyle(
                          fontSize: 30,
                          fontWeight: FontWeight.w800,
                          height: 1.1,
                          color: scheme.primary,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        s.label,
                        style: TextStyle(
                          fontSize: 13,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
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

/// What customers say, with a name against it.
///
/// Ships empty and stays empty until somebody writes one. A testimonial
/// nobody said is a fabricated endorsement whatever else it is, so
/// there is no built-in copy here to fall back to and the author is
/// rendered every time — an unattributed quote on a page selling
/// software is exactly the shape an invented one takes.
class _Testimonials extends StatelessWidget {
  const _Testimonials({required this.testimonials});

  final List<LandingTestimonial> testimonials;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'What customers say',
          style: TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.w700,
            color: scheme.onSurface,
          ),
        ),
        const SizedBox(height: 20),
        LayoutBuilder(
          builder: (context, constraints) {
            final columns = constraints.maxWidth > 860
                ? 3
                : constraints.maxWidth > 560
                    ? 2
                    : 1;
            final width =
                (constraints.maxWidth - (columns - 1) * 20) / columns;
            return Wrap(
              spacing: 20,
              runSpacing: 20,
              children: [
                for (final t in testimonials)
                  SizedBox(
                    width: width,
                    child: RevealOnScroll(
                      delay: Duration(
                        milliseconds:
                            60 * (testimonials.indexOf(t) % 6),
                      ),
                      child: Container(
                        padding: const EdgeInsets.all(20),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(14),
                          color: scheme.surfaceContainerLowest,
                          border: Border.all(color: scheme.outlineVariant),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Icon(
                              Icons.format_quote,
                              color: scheme.primary.withValues(alpha: 0.6),
                              size: 26,
                            ),
                            const SizedBox(height: 8),
                            Text(
                              t.quote,
                              style: const TextStyle(
                                fontSize: 15,
                                height: 1.55,
                              ),
                            ),
                            const SizedBox(height: 14),
                            Row(
                              children: [
                                if (t.avatarUrl != null) ...[
                                  ClipOval(
                                    child: Image.network(
                                      t.avatarUrl!,
                                      width: 32,
                                      height: 32,
                                      fit: BoxFit.cover,
                                      errorBuilder: (_, __, ___) =>
                                          const SizedBox.shrink(),
                                    ),
                                  ),
                                  const SizedBox(width: 10),
                                ],
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        t.author,
                                        style: const TextStyle(
                                          fontSize: 14,
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                      if (t.company != null)
                                        Text(
                                          t.company!,
                                          style: TextStyle(
                                            fontSize: 12,
                                            color: scheme.onSurfaceVariant,
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
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
        Text(
          'Businesses running on iAkauntan',
          style: TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w600,
            color: scheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 18),
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
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: scheme.onSurfaceVariant,
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
