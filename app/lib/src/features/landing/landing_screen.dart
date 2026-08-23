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
