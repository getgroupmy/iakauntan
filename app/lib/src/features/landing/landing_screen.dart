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
    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1080),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 32,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _Masthead(content: content),
                    const SizedBox(height: 48),
                    RevealOnScroll(child: _Hero(content: content)),
                    if (content.sections.isNotEmpty) ...[
                      const SizedBox(height: 56),
                      _Sections(sections: content.sections),
                    ],
                    // Somewhere to press, for a visitor who has read
                    // the feature grid and does not need the rest.
                    if (content.ctaHeadline != null) ...[
                      const SizedBox(height: 64),
                      RevealOnScroll(child: _Cta(content: content)),
                    ],
                    if (content.reasons.isNotEmpty) ...[
                      const SizedBox(height: 64),
                      _Reasons(reasons: content.reasons),
                    ],
                    // The three that ship empty. Each renders nothing
                    // at all until an operator has written rows, which
                    // is the correct page for a platform that has not
                    // made a claim rather than a gap to fill with
                    // invented ones.
                    if (content.stats.isNotEmpty) ...[
                      const SizedBox(height: 56),
                      RevealOnScroll(child: _Stats(stats: content.stats)),
                    ],
                    if (content.testimonials.isNotEmpty) ...[
                      const SizedBox(height: 64),
                      _Testimonials(testimonials: content.testimonials),
                    ],
                    if (content.logos.isNotEmpty) ...[
                      const SizedBox(height: 56),
                      RevealOnScroll(child: _Logos(logos: content.logos)),
                    ],
                    if (content.showPricing &&
                        content.modules.isNotEmpty) ...[
                      const SizedBox(height: 64),
                      RevealOnScroll(
                        delay: const Duration(milliseconds: 60),
                        child: LandingPricing(content: content),
                      ),
                    ],
                    if (content.appLinks.isNotEmpty) ...[
                      const SizedBox(height: 56),
                      RevealOnScroll(
                        child: _AppLinks(links: content.appLinks),
                      ),
                    ],
                    const SizedBox(height: 56),
                    _Footer(content: content),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The logo and the wordmark, with the sign-in button beside them.
class _Masthead extends StatelessWidget {
  const _Masthead({required this.content});

  final LandingContent content;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        LandingMark(content: content),
        const Spacer(),
        TextButton(
          onPressed: () => context.go('/signin'),
          child: Text(content.signInLabel),
        ),
        if (content.registerEnabled) ...[
          const SizedBox(width: 8),
          FilledButton(
            onPressed: () => context.go('/signin?mode=register'),
            child: Text(content.registerLabel),
          ),
        ],
      ],
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

class _Hero extends StatelessWidget {
  const _Hero({required this.content});

  final LandingContent content;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (content.tagline != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(
              content.tagline!,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                letterSpacing: 1.2,
                color: scheme.primary,
              ),
            ),
          ),
        Text(
          content.heroHeadline,
          style: TextStyle(
            fontSize: 40,
            height: 1.15,
            fontWeight: FontWeight.w700,
            letterSpacing: -1,
            color: scheme.onSurface,
          ),
        ),
        if (content.heroSubhead != null) ...[
          const SizedBox(height: 16),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: Text(
              content.heroSubhead!,
              style: TextStyle(
                fontSize: 17,
                height: 1.5,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
        const SizedBox(height: 28),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            FilledButton.icon(
              onPressed: () => context.go('/signin'),
              icon: const Icon(Icons.login),
              label: Text(content.signInLabel),
            ),
            if (content.registerEnabled)
              OutlinedButton.icon(
                onPressed: () => context.go('/signin?mode=register'),
                icon: const Icon(Icons.person_add_alt),
                label: Text(content.registerLabel),
              ),
          ],
        ),
      ],
    );
  }
}

class _Sections extends StatelessWidget {
  const _Sections({required this.sections});

  final List<LandingSection> sections;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = constraints.maxWidth > 820
            ? 3
            : constraints.maxWidth > 520
                ? 2
                : 1;
        final width =
            (constraints.maxWidth - (columns - 1) * 20) / columns;
        return Wrap(
          spacing: 20,
          runSpacing: 20,
          children: [
            for (final s in sections)
              SizedBox(
                width: width,
                child: RevealOnScroll(
                  // Staggered by position so a row arrives as a row.
                  // Capped, or the last card on a long page waits a
                  // second and a half to say anything.
                  delay: Duration(
                    milliseconds: 60 * (sections.indexOf(s) % 6),
                  ),
                  child: HoverLift(
                    builder: (context, hovered) => AnimatedContainer(
                      duration: const Duration(milliseconds: 160),
                      padding: const EdgeInsets.all(18),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(12),
                        color: hovered
                            ? scheme.surfaceContainerLowest
                            : Colors.transparent,
                        border: Border.all(
                          color: hovered
                              ? scheme.outlineVariant
                              : Colors.transparent,
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          AnimatedContainer(
                            duration: const Duration(milliseconds: 160),
                            padding: const EdgeInsets.all(9),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(10),
                              color: scheme.primary.withValues(
                                alpha: hovered ? 0.16 : 0.09,
                              ),
                            ),
                            child: Icon(
                              landingIcon(s.icon),
                              color: scheme.primary,
                              size: 22,
                            ),
                          ),
                          const SizedBox(height: 12),
                          Text(
                            s.title,
                            style: const TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          if (s.body != null) ...[
                            const SizedBox(height: 6),
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
                ),
              ),
          ],
        );
      },
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

class _Footer extends StatelessWidget {
  const _Footer({required this.content});

  final LandingContent content;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final small = TextStyle(fontSize: 13, color: scheme.onSurfaceVariant);
    final lines = <String>[
      if (content.companyName != null)
        content.companyRegNo != null
            ? '${content.companyName} (${content.companyRegNo})'
            : content.companyName!,
      if (content.address != null) content.address!,
      if (content.supportEmail != null) content.supportEmail!,
      if (content.supportPhone != null) content.supportPhone!,
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Divider(color: scheme.outlineVariant),
        const SizedBox(height: 16),
        for (final line in lines)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(line, style: small),
          ),
        if (content.privacyUrl != null || content.termsUrl != null) ...[
          const SizedBox(height: 8),
          Wrap(
            spacing: 16,
            children: [
              if (content.privacyUrl != null)
                TextButton(
                  onPressed: () => launchExternal(content.privacyUrl),
                  child: const Text('Privacy'),
                ),
              if (content.termsUrl != null)
                TextButton(
                  onPressed: () => launchExternal(content.termsUrl),
                  child: const Text('Terms'),
                ),
            ],
          ),
        ],
      ],
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
/// Two columns of short reasons rather than the feature grid's cards:
/// the same rows from `landing_sections`, split by `kind`, laid out so
/// the two bands do not read as the same band twice.
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
            fontSize: 22,
            fontWeight: FontWeight.w700,
            color: scheme.onSurface,
          ),
        ),
        const SizedBox(height: 20),
        LayoutBuilder(
          builder: (context, constraints) {
            final columns = constraints.maxWidth > 720 ? 2 : 1;
            final width =
                (constraints.maxWidth - (columns - 1) * 28) / columns;
            return Wrap(
              spacing: 28,
              runSpacing: 24,
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
                          Icon(
                            landingIcon(r.icon),
                            color: scheme.primary,
                            size: 22,
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  r.title,
                                  style: const TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                if (r.body != null) ...[
                                  const SizedBox(height: 6),
                                  Text(
                                    r.body!,
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
