import 'package:flutter/material.dart';

import 'landing_carousel.dart';
import 'landing_content.dart';
import 'landing_motion.dart';
import 'landing_tokens.dart';

/// The dark band, and the product cards on it.
///
/// The one structural device this page did not have and the reference
/// site leans on hardest: a full-width band inverted against everything
/// around it, carrying the modules as cards. On a page that is
/// otherwise white and faint grey the whole way down, one dark band is
/// what stops the middle reading as a single undifferentiated scroll.
///
/// It draws the module catalogue — `platform_modules`, the same rows
/// the pricing picker uses — because those are the things a company
/// actually buys, and naming them is a claim about what is on sale
/// rather than about anybody's results.
///
/// Prices are deliberately not on these cards: the band says what there
/// is, and the pricing block below says what it costs.
///
/// Note that the band appears only when `show_pricing` is on, because
/// `app.landing_payload` gates the `modules` collection behind it.
/// Whether a platform should be able to list its modules without
/// publishing a rate card is a fair question and the answer today is
/// no; this widget does not get to route around the switch.
class LandingDarkBand extends StatelessWidget {
  const LandingDarkBand({super.key, required this.modules});

  final List<LandingModule> modules;

  @override
  Widget build(BuildContext context) {
    // Fixed dark rather than the theme's dark scheme. This band is dark
    // in both light and dark mode — that is what makes it a band rather
    // than a section, and in dark mode it sits a step below the page
    // instead of above it.
    const ink = Color(0xFF0F172A);
    const inkSoft = Color(0xFF1E293B);
    final scheme = Theme.of(context).colorScheme;
    final onInk = Colors.white.withValues(alpha: 0.72);

    return Container(
      width: double.infinity,
      color: ink,
      padding: const EdgeInsets.symmetric(
        horizontal: Land.gutter,
        vertical: Land.bandY,
      ),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: Land.maxWidth),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(999),
                  color: scheme.primary.withValues(alpha: 0.18),
                  border: Border.all(
                    color: scheme.primary.withValues(alpha: 0.35),
                  ),
                ),
                child: Text(
                  'MODULES',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.9,
                    color: scheme.primary,
                  ),
                ),
              ),
              const SizedBox(height: Land.gap),
              Text(
                'Turn on what the business needs',
                style: Land.heading(scheme).copyWith(color: Colors.white),
              ),
              const SizedBox(height: 12),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 640),
                child: Text(
                  'The books are the core. Everything else is a module a '
                  'company switches on when it needs it, and not before.',
                  style: Land.body(scheme).copyWith(color: onInk),
                ),
              ),
              const SizedBox(height: Land.gapLg),
              // Paged rather than wrapped. Twenty-five modules in a
              // grid is a wall a reader skips; four at a time with
              // arrows is a thing they page through.
              LayoutBuilder(
                builder: (context, constraints) {
                  final perPage = constraints.maxWidth > 980
                      ? 4
                      : constraints.maxWidth > 700
                          ? 3
                          : constraints.maxWidth > 460
                              ? 2
                              : 1;
                  return RevealOnScroll(
                    child: LandingCarousel(
                      perPage: perPage,
                      // Tall enough for the longest description at the
                      // narrowest card, since a PageView cannot size
                      // itself to its children.
                      height: perPage == 1 ? 168 : 196,
                      onInk: true,
                      items: [
                        for (final m in modules)
                          _ModuleCard(module: m, ink: inkSoft, onInk: onInk),
                      ],
                    ),
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ModuleCard extends StatelessWidget {
  const _ModuleCard({
    required this.module,
    required this.ink,
    required this.onInk,
  });

  final LandingModule module;
  final Color ink;
  final Color onInk;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return HoverLift(
      builder: (context, hovered) => AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(Land.radius),
          color: hovered ? ink : ink.withValues(alpha: 0.6),
          border: Border.all(
            color: hovered
                ? scheme.primary.withValues(alpha: 0.55)
                : Colors.white.withValues(alpha: 0.10),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    module.name,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: Colors.white,
                    ),
                  ),
                ),
                // What a company holds without buying anything, said on
                // the card rather than left to the pricing block: it is
                // the difference between an add-on and the product.
                if (module.isCore)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 7,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(999),
                      color: scheme.primary.withValues(alpha: 0.22),
                    ),
                    child: Text(
                      'Core',
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        color: scheme.primary,
                      ),
                    ),
                  ),
              ],
            ),
            if (module.description != null &&
                module.description!.trim().isNotEmpty) ...[
              const SizedBox(height: 7),
              Text(
                module.description!,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 13, height: 1.5, color: onInk),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
